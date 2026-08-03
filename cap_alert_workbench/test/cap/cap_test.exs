defmodule CapAlertWorkbench.CapTest do
  use CapAlertWorkbench.DataCase, async: false

  alias CapAlertWorkbench.Cap
  alias CapAlertWorkbench.Cap.{AuditEvent, OutboxMessage, Version}
  alias CapAlertWorkbench.Repo

  import Ecto.Query

  defp seed_attrs(overrides) do
    message = Cap.Xml.Codec.seed_message(overrides)

    message
    |> Map.from_struct()
    |> Map.put(:actor, "test-officer")
    |> Map.to_list()
  end

  defp create_alert(overrides \\ []) do
    {:ok, %{alert: alert}} = Cap.create_alert(seed_attrs(overrides))
    alert
  end

  describe "create_alert/1" do
    test "creates an initial draft and an audit event" do
      alert = create_alert()
      assert alert.identifier == "CN-20260729-GD-RAIN-001"
      assert alert.status == :draft
      assert alert.draft_lock_version == 1
      assert alert.draft_revision == 1

      audits = Cap.list_audit_events(alert.id)
      assert Enum.any?(audits, &(&1.action == "draft_created"))
    end

    test "rejects invalid area codes" do
      assert {:error, {:invalid_area_code, "999999"}} =
               Cap.create_alert(seed_attrs(area_codes: ["999999"]))
    end
  end

  describe "update_draft/4 optimistic locking" do
    test "updates and increments both lock version and revision" do
      alert = create_alert()

      assert {:ok, %{alert: updated}} =
               Cap.update_draft(alert.id, 1, %{"headline" => "新标题"}, "editor")

      assert updated.draft_lock_version == 2
      assert updated.draft_revision == 2
      assert updated.draft_payload["headline"] == "新标题"

      audits = Cap.list_audit_events(alert.id)
      assert Enum.any?(audits, &(&1.action == "draft_updated"))
    end

    test "rejects stale lock version to simulate two browsers editing the same draft" do
      alert = create_alert()

      assert {:ok, %{alert: _}} =
               Cap.update_draft(alert.id, 1, %{"headline" => "浏览器A的修改"}, "A")

      assert {:error, {:lock_version_mismatch, 2, 1}} =
               Cap.update_draft(alert.id, 1, %{"headline" => "浏览器B的旧修改"}, "B")
    end
  end

  describe "review workflow and stale review race" do
    test "submitting, approving and publishing creates immutable versions" do
      alert = create_alert()

      assert {:ok, %{alert: submitted}} = Cap.submit_for_review(alert.id, "author")
      assert submitted.status == :in_review

      assert {:ok, %{alert: reviewed}} =
               Cap.decide_review(
                 submitted.id,
                 %{"decision" => "approved", "comment" => "可以发布"},
                 "reviewer"
               )

      assert reviewed.status == :approved

      assert {:ok, %{alert: published, publish: %{version: version}}} =
               Cap.publish(reviewed.id, "publisher")

      assert published.status == :published
      assert published.latest_published_version == 1
      assert version.status == :published
      assert is_binary(version.xml_snapshot)

      # The snapshot is immutable: published version XML exists
      assert {:ok, xml} = Cap.version_xml(published.id, 1)
      assert xml =~ "<identifier>CN-20260729-GD-RAIN-001</identifier>"
    end

    test "a review decision racing with a new draft edit is rejected as stale" do
      alert = create_alert()
      {:ok, %{alert: submitted}} = Cap.submit_for_review(alert.id, "author")

      # Editor modifies the draft while review is in flight. The edit invalidates
      # the review and returns the alert to the draft state.
      assert {:ok, %{alert: edited}} =
               Cap.update_draft(submitted.id, 1, %{"headline" => "修订标题"}, "editor")

      assert edited.draft_revision == 2
      assert edited.status == :draft

      # The old review decision cannot be applied. The service rejects it either
      # because the alert is no longer in_review or because of revision mismatch.
      result =
        Cap.decide_review(
          submitted.id,
          %{"decision" => "approved", "comment" => "基于旧版本"},
          "reviewer"
        )

      assert {:error, reason} = result
      assert reason in [{:invalid_status, :draft}, {:stale_review, 1, 2}]
    end

    test "changes_requested returns the alert to rejected state" do
      alert = create_alert()
      {:ok, %{alert: submitted}} = Cap.submit_for_review(alert.id, "author")

      assert {:ok, %{alert: reviewed}} =
               Cap.decide_review(
                 submitted.id,
                 %{"decision" => "changes_requested", "comment" => "请补充影响时段"},
                 "reviewer"
               )

      assert reviewed.status == :rejected
    end
  end

  describe "publish idempotency and immutability" do
    test "duplicate publish is rejected" do
      alert = create_alert()
      {:ok, %{alert: submitted}} = Cap.submit_for_review(alert.id, "author")

      {:ok, %{alert: reviewed}} =
        Cap.decide_review(submitted.id, %{"decision" => "approved"}, "reviewer")

      assert {:ok, %{alert: published}} = Cap.publish(reviewed.id, "publisher")
      assert published.status == :published

      assert {:error, :already_published} = Cap.publish(reviewed.id, "publisher")
    end

    test "published content cannot be edited through the draft API" do
      alert = create_alert()
      {:ok, %{alert: submitted}} = Cap.submit_for_review(alert.id, "author")

      {:ok, %{alert: reviewed}} =
        Cap.decide_review(submitted.id, %{"decision" => "approved"}, "r")

      {:ok, %{alert: published}} = Cap.publish(reviewed.id, "publisher")

      # update_draft locks FOR UPDATE and then writes; but after publication the
      # status is :published. The service still allows draft edits only if the
      # alert is in an editable status, so verify it rejects accordingly.
      result =
        Cap.update_draft(published.id, published.draft_lock_version, %{"headline" => "x"}, "e")

      assert {:error, _} = result
    end
  end

  describe "correction and cancellation" do
    setup do
      alert = create_alert()
      {:ok, %{alert: submitted}} = Cap.submit_for_review(alert.id, "author")

      {:ok, %{alert: reviewed}} =
        Cap.decide_review(submitted.id, %{"decision" => "approved"}, "r")

      {:ok, %{alert: published}} = Cap.publish(reviewed.id, "publisher")
      %{alert: published}
    end

    test "creates a correction update version and supersedes the original", %{alert: alert} do
      assert {:ok, %{alert: corrected, new_version: %{version: new_version}}} =
               Cap.create_correction(
                 alert.id,
                 %{"headline" => "暴雨红色预警更新", "note" => "雨区北抬"},
                 "publisher"
               )

      assert corrected.status == :published
      assert corrected.latest_published_version == 2
      assert new_version.kind == :correction
      assert new_version.status == :published

      versions = Cap.list_versions(alert.id)
      assert length(versions) == 2
      assert Enum.any?(versions, &(&1.status == :superseded))
    end

    test "creates a cancellation cancel version", %{alert: alert} do
      assert {:ok, %{alert: canceled, new_version: %{version: version}}} =
               Cap.create_cancellation(alert.id, %{"note" => "降雨减弱，解除预警"}, "publisher")

      assert canceled.status == :canceled
      assert version.kind == :cancellation
      assert version.status == :canceled
    end
  end

  describe "transactional audit and outbox" do
    test "audit events and outbox messages are committed with the state change" do
      alert = create_alert()

      outbox_count_before =
        Repo.aggregate(from(o in OutboxMessage, where: o.alert_id == ^alert.id), :count)

      audits_before =
        Repo.aggregate(from(e in AuditEvent, where: e.alert_id == ^alert.id), :count)

      {:ok, _} = Cap.submit_for_review(alert.id, "author")

      outbox_count_after =
        Repo.aggregate(from(o in OutboxMessage, where: o.alert_id == ^alert.id), :count)

      audits_after =
        Repo.aggregate(from(e in AuditEvent, where: e.alert_id == ^alert.id), :count)

      assert outbox_count_after == outbox_count_before + 1
      assert audits_after == audits_before + 1

      outbox =
        from(o in OutboxMessage, where: o.alert_id == ^alert.id, order_by: [desc: o.inserted_at])
        |> Repo.one()

      assert outbox.topic == "alert.review.submitted"
      assert outbox.status == :pending
    end

    test "published versions cannot be mutated through the changeset" do
      alert = create_alert()
      {:ok, _} = Cap.submit_for_review(alert.id, "author")
      {:ok, _} = Cap.decide_review(alert.id, %{"decision" => "approved"}, "r")
      {:ok, _} = Cap.publish(alert.id, "publisher")

      version =
        Version
        |> where([v], v.alert_id == ^alert.id and v.status == :published)
        |> Repo.one!()

      changeset = Version.changeset(version, %{review_note: "tampered"})
      refute changeset.valid?
      assert {:error, _} = Repo.update(changeset)
    end
  end

  describe "diff_versions/3" do
    test "reports changed fields between two versions" do
      alert = create_alert()
      {:ok, _} = Cap.submit_for_review(alert.id, "author")

      # After submit the alert is in_review; editing returns it to draft and
      # creates a new revision. Resubmit to produce a second immutable version.
      {:ok, %{alert: updated}} =
        Cap.update_draft(alert.id, 1, %{"headline" => "变更后的标题"}, "editor")

      assert updated.status == :draft
      {:ok, _} = Cap.submit_for_review(updated.id, "editor")

      assert {:ok, changes} = Cap.diff_versions(alert.id, 1, 2)
      assert Enum.any?(changes, &(&1.field == "headline" and &1.change == :modified))
    end
  end
end
