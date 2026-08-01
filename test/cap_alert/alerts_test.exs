defmodule CapAlertWorkbench.CapAlert.AlertsTest do
  use CapAlertWorkbench.DataCase, async: false

  alias CapAlertWorkbench.CapAlert
  alias CapAlertWorkbench.CapAlert.{AuditEvent, NotificationOutbox}

  @initial_attrs %{
    "identifier" => "CN-20260729-GD-RAIN-001",
    "sender" => "duty-officer@gd.example",
    "sent" => ~U[2026-07-29 08:00:00Z],
    "status" => "actual",
    "msg_type" => "alert",
    "scope" => "public",
    "language" => "zh-CN",
    "event" => "暴雨",
    "headline" => "暴雨红色预警",
    "description" => "预计未来6小时降雨量将达100毫米以上",
    "instruction" => "停止集会、停课、停业",
    "urgency" => "immediate",
    "severity" => "severe",
    "certainty" => "likely",
    "geocodes" => %{
      "0" => %{"value_name" => "Same", "value" => "440800"},
      "1" => %{"value_name" => "Same", "value" => "440900"}
    }
  }

  defp create_alert!(attrs \\ @initial_attrs) do
    {:ok, %{alert: alert, version: version}} = CapAlert.create_alert(attrs, "test-author")
    {alert, version}
  end

  defp submit!(version) do
    {:ok, v} = CapAlert.submit_for_review(version, "editor")
    v
  end

  defp approve!(version) do
    {:ok, v} = CapAlert.review(version, :approve, "同意发布", "reviewer")
    v
  end

  defp publish!(version) do
    {:ok, p} = CapAlert.publish(version, "publisher")
    p
  end

  defp count(query), do: CapAlertWorkbench.Repo.aggregate(query, :count)

  describe "create_alert/2" do
    test "creates the initial draft with the specified CAP fields" do
      {alert, version} = create_alert!()

      assert alert.identifier == "CN-20260729-GD-RAIN-001"
      assert alert.latest_version_id == version.id
      assert version.version_number == 1
      assert version.workflow_state == :draft
      assert version.status == :actual
      assert version.msg_type == :alert
      assert version.scope == :public
      assert version.language == "zh-CN"
      assert version.urgency == :immediate
      assert version.severity == :severe
      assert version.certainty == :likely
      assert Enum.map(version.geocodes, & &1.value) == ["440800", "440900"]

      audit = CapAlert.list_audit_events(alert.identifier)
      assert Enum.any?(audit, &(&1.action == "created"))
    end

    test "rejects invalid identifier" do
      assert {:error, %Ecto.Changeset{}} =
               CapAlert.create_alert(%{@initial_attrs | "identifier" => "bad id"}, "t")
    end
  end

  describe "edit_draft/3" do
    test "edits an editable draft and increments lock_version" do
      {_alert, version} = create_alert!()
      assert version.lock_version == 1

      {:ok, updated} =
        CapAlert.edit_draft(version, %{"headline" => "新标题", "lock_version" => 1}, "editor")

      assert updated.headline == "新标题"
      assert updated.lock_version == 2

      audit = CapAlert.list_audit_events(version.alert_identifier)
      assert Enum.any?(audit, &(&1.action == "edited"))
    end

    test "returns :stale when lock_version does not match (optimistic lock)" do
      {_alert, version} = create_alert!()

      # First browser saves successfully, bumping lock_version to 2
      {:ok, _} =
        CapAlert.edit_draft(version, %{"headline" => "A", "lock_version" => 1}, "browser-1")

      # Second browser still holds lock_version = 1 -> conflict
      assert {:error, :stale} =
               CapAlert.edit_draft(
                 version,
                 %{"headline" => "B", "lock_version" => 1},
                 "browser-2"
               )
    end

    test "cannot edit a published version" do
      {_alert, version} = create_alert!()
      version = version |> submit!() |> approve!()
      {:ok, published} = CapAlert.publish(version, "publisher")

      assert {:error, :not_editable} =
               CapAlert.edit_draft(published, %{"headline" => "hacked"}, "attacker")
    end
  end

  describe "review and publish workflow" do
    test "submit -> approve -> publish with atomic audit and outbox" do
      {_alert, version} = create_alert!()
      assert version.workflow_state == :draft

      submitted = submit!(version)
      assert submitted.workflow_state == :in_review

      approved = approve!(submitted)
      assert approved.workflow_state == :approved

      assert {:ok, published} = CapAlert.publish(approved, "publisher")
      assert published.workflow_state == :published
      assert published.published_at != nil
      assert published.xml_payload =~ "<alert xmlns=\"urn:oasis:names:tc:emergency:cap:1.2\""
      assert published.xml_payload =~ "CN-20260729-GD-RAIN-001"
      assert published.xml_payload =~ "440800"

      alert = CapAlert.get_alert!(version.alert_identifier)
      assert alert.published_version_id == published.id

      audit = CapAlert.list_audit_events(version.alert_identifier)
      actions = Enum.map(audit, & &1.action)
      assert "published" in actions
      assert "approve" in actions
      assert "submit" in actions

      outbox = CapAlert.list_outbox(version.alert_identifier)
      assert length(outbox) == 1
      assert hd(outbox).status == :pending
      assert hd(outbox).event_type == "alert.alert"
    end

    test "rejecting returns the draft to changes_requested" do
      {_alert, version} = create_alert!()
      submitted = submit!(version)

      {:ok, rejected} = CapAlert.review(submitted, :reject, "请补充区域信息", "reviewer")
      assert rejected.workflow_state == :changes_requested
      assert rejected.review_comment == "请补充区域信息"

      # Can edit again after rejection
      {:ok, edited} = CapAlert.edit_draft(rejected, %{"description" => "补充"}, "editor")
      assert edited.workflow_state == :changes_requested
    end

    test "stale review is rejected after a newer draft is created" do
      {_alert, version} = create_alert!()
      submitted = submit!(version)

      # Author creates a new draft while review is pending
      {:ok, new_draft} = CapAlert.revise(submitted, "author")
      assert new_draft.version_number == 2
      assert new_draft.workflow_state == :draft

      # The old in-review version is no longer latest -> review must fail
      assert {:error, :not_latest} =
               CapAlert.review(submitted, :approve, "old conclusion", "reviewer")
    end

    test "cannot publish a non-approved version" do
      {_alert, version} = create_alert!()
      assert {:error, :not_publishable} = CapAlert.publish(version, "publisher")
    end
  end

  describe "duplicate publish (concurrency)" do
    test "only one concurrent publish succeeds; the other is rejected" do
      {_alert, version} = create_alert!()
      version = version |> submit!() |> approve!()

      parent = self()
      ref = make_ref()

      tasks =
        for i <- 1..2 do
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(CapAlertWorkbench.Repo, parent, self())
            result = CapAlert.publish(version, "publisher-#{i}")
            send(parent, {ref, i, result})
            result
          end)
        end

      Task.await_many(tasks, 10_000)

      results =
        for _ <- 1..2 do
          receive do
            {^ref, _i, result} -> result
          after
            5_000 -> flunk("timeout waiting for publish result")
          end
        end

      success = Enum.filter(results, &match?({:ok, _}, &1))
      failures = Enum.filter(results, &match?({:error, _}, &1))

      assert length(success) == 1
      assert length(failures) == 1

      # Exactly one published audit event and one outbox row, no duplicates
      assert count(
               from a in AuditEvent,
                 where:
                   a.alert_identifier == ^version.alert_identifier and a.action == "published"
             ) == 1

      assert count(
               from o in NotificationOutbox,
                 where: o.alert_identifier == ^version.alert_identifier
             ) == 1
    end
  end

  describe "publish transaction atomicity" do
    test "mid-transaction failure rolls back version state, audit, and outbox" do
      {_alert, version} = create_alert!()
      version = version |> submit!() |> approve!()

      Application.put_env(:cap_alert_workbench, :simulate_publish_failure, true)

      try do
        assert {:error, :simulated_failure} = CapAlert.publish(version, "publisher")
      after
        Application.delete_env(:cap_alert_workbench, :simulate_publish_failure)
      end

      # Version must remain approved (not published) because the transaction rolled back
      reloaded = CapAlert.get_version!(version.id)
      assert reloaded.workflow_state == :approved
      assert reloaded.published_at == nil

      # No published audit event, no outbox row
      assert count(
               from a in AuditEvent,
                 where:
                   a.alert_identifier == ^version.alert_identifier and a.action == "published"
             ) == 0

      assert count(
               from o in NotificationOutbox,
                 where: o.alert_identifier == ^version.alert_identifier
             ) == 0
    end
  end

  describe "correction and cancellation" do
    setup do
      {_alert, version} = create_alert!()
      published = version |> submit!() |> approve!() |> publish!()
      %{published: published}
    end

    test "create_correction produces an Update draft referencing the published version", %{
      published: p
    } do
      assert {:ok, correction} =
               CapAlert.create_correction(
                 %{"alert_identifier" => p.alert_identifier, "headline" => "更新后的标题"},
                 "editor"
               )

      assert correction.msg_type == :update
      assert correction.workflow_state == :draft
      assert correction.based_on_version_id == p.id
      assert correction.references =~ p.alert_identifier
      assert correction.references =~ p.sender

      # Go through review and publish; original becomes superseded
      {:ok, submitted} = CapAlert.submit_for_review(correction, "editor")
      {:ok, approved} = CapAlert.review(submitted, :approve, "", "reviewer")
      {:ok, new_published} = CapAlert.publish(approved, "publisher")

      assert new_published.workflow_state == :published
      original = CapAlert.get_version!(p.id)
      assert original.workflow_state == :superseded
    end

    test "create_cancellation produces a Cancel draft and marks the alert cancelled", %{
      published: p
    } do
      assert {:ok, cancellation} =
               CapAlert.create_cancellation(
                 %{
                   "alert_identifier" => p.alert_identifier,
                   "headline" => "预警解除",
                   "description" => "降雨结束"
                 },
                 "editor"
               )

      assert cancellation.msg_type == :cancel
      assert cancellation.references =~ p.alert_identifier

      {:ok, submitted} = CapAlert.submit_for_review(cancellation, "editor")
      {:ok, approved} = CapAlert.review(submitted, :approve, "", "reviewer")
      {:ok, cancelled_pub} = CapAlert.publish(approved, "publisher")
      assert cancelled_pub.workflow_state == :published

      alert = CapAlert.get_alert!(p.alert_identifier)
      assert alert.state == :cancelled
      original = CapAlert.get_version!(p.id)
      assert original.workflow_state == :cancelled
    end

    test "cannot create follow-up without a published version" do
      {:ok, %{alert: alert}} =
        CapAlert.create_alert(
          %{@initial_attrs | "identifier" => "CN-NEW-002"},
          "t"
        )

      assert {:error, :no_published_version} =
               CapAlert.create_correction(%{"alert_identifier" => alert.identifier}, "t")
    end
  end

  describe "version diff" do
    test "detects changed fields" do
      {_alert, v1} = create_alert!()
      {:ok, v2} = CapAlert.edit_draft(v1, %{"headline" => "变更后标题"}, "editor")

      diff = CapAlert.diff_versions(v1, v2)
      headline_change = Enum.find(diff, &(&1.field == :headline))
      assert headline_change.changed
      assert headline_change.old =~ "暴雨红色预警"
      assert headline_change.new == "变更后标题"

      unchanged = Enum.find(diff, &(&1.field == :event))
      refute unchanged.changed
    end
  end

  describe "CAP XML export/import through the context" do
    test "export then import round-trips the structured fields" do
      {_alert, version} = create_alert!()
      xml = CapAlert.export_cap(version)
      assert is_binary(xml)

      assert {:ok, %{alert: alert, version: imported}} =
               CapAlert.import_cap(xml, "importer")

      assert alert.identifier == "CN-20260729-GD-RAIN-001"
      assert imported.event == "暴雨"
      assert imported.severity == :severe
      assert imported.status == :actual
      assert Enum.map(imported.geocodes, & &1.value) |> Enum.sort() == ["440800", "440900"]
    end

    test "import rejects external entity documents" do
      xml =
        ~s(<?xml version="1.0"?><!DOCTYPE foo [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>) <>
          ~s(<alert xmlns="urn:oasis:names:tc:emergency:cap:1.2"><identifier>x</identifier></alert>)

      assert {:error, :doctype_or_entity_forbidden} = CapAlert.import_cap(xml, "importer")
    end
  end
end
