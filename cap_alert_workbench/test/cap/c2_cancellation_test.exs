defmodule CapAlertWorkbench.Cap.C2CancellationTest do
  use CapAlertWorkbench.DataCase, async: false

  alias CapAlertWorkbench.Cap
  alias CapAlertWorkbench.Cap.{AuditEvent, Message, OutboxMessage, Version}
  alias CapAlertWorkbench.Repo

  import Ecto.Query

  defp publish_initial(overrides \\ []) do
    message = Cap.Xml.Codec.seed_message(overrides)

    attrs =
      message
      |> Map.from_struct()
      |> Map.put(:actor, "officer")
      |> Map.to_list()

    {:ok, %{alert: alert}} = Cap.create_alert(attrs)
    {:ok, _} = Cap.submit_for_review(alert.id, "officer")
    {:ok, _} = Cap.decide_review(alert.id, %{"decision" => "approved"}, "reviewer")
    {:ok, %{alert: published}} = Cap.publish(alert.id, "publisher")
    {:ok, _} = Cap.create_correction_c1(published.id, "publisher")
    Cap.get_alert!(published.id)
  end

  describe "create_cancellation_c2/2" do
    test "derives from the round-2 published C1 and references only C1" do
      alert = publish_initial()

      assert {:ok, result} = Cap.create_cancellation_c2(alert.id, "publisher")
      version = result.new_version.version

      assert version.status == :canceled
      assert version.kind == :cancellation
      assert version.version_number == 3
      assert version.payload["identifier"] == "CN-20260729-GD-RAIN-001-C2"
      assert version.payload["msg_type"] == "cancel"
      assert version.payload["note"] == "预警解除 C2"

      c1 = Repo.one!(from v in Version, where: v.alert_id == ^alert.id and v.version_number == 2)

      # references point precisely at the C1 document (single reference).
      assert length(version.references) == 1
      [ref] = version.references
      assert ref =~ "CN-20260729-GD-RAIN-001-C1,"
      refute ref =~ "CN-20260729-GD-RAIN-001,"

      assert ref ==
               "#{c1.payload["sender"]},#{c1.payload["identifier"]}," <>
                 Cap.Xml.Codec.format_ref_time(c1.payload["sent_at"])

      # The alert is now canceled and points at version 3.
      reloaded = Cap.get_alert!(alert.id)
      assert reloaded.status == :canceled
      assert reloaded.latest_published_version == 3
    end

    test "preserves the validated multi-info structure and area-level severities" do
      alert = publish_initial()
      {:ok, result} = Cap.create_cancellation_c2(alert.id, "publisher")
      version = result.new_version.version

      message = Cap.Xml.Codec.decode!(version.xml_snapshot)
      assert message.msg_type == :cancel
      assert length(message.infos) == 2

      # Both areas keep their own info segment with the C1 severity.
      assert Message.info_for_area(message, "440800").severity == :severe
      assert Message.info_for_area(message, "440900").severity == :extreme

      assert Enum.sort(Message.area_codes(message)) == ["440800", "440900"]

      # The XML round-trips byte-for-byte.
      assert {:ok, decoded} = Cap.Xml.Codec.decode(version.xml_snapshot)
      assert Cap.Xml.Codec.encode!(decoded) == version.xml_snapshot
    end

    test "supersedes C1 and leaves the full version chain viewable" do
      alert = publish_initial()
      {:ok, _} = Cap.create_cancellation_c2(alert.id, "publisher")

      versions = Cap.list_versions(alert.id)
      assert length(versions) == 3

      by_number = Map.new(versions, &{&1.version_number, &1})

      # Version 1 (draft -> published) is immutable history.
      assert by_number[1].kind == :draft
      assert by_number[1].status in [:published, :superseded]

      # C1 was superseded by C2.
      assert by_number[2].status == :superseded
      assert by_number[2].superseded_by == by_number[3].id
      assert by_number[2].kind == :correction

      # C2 is the canceled tip.
      assert by_number[3].status == :canceled
      assert by_number[3].kind == :cancellation

      # The chain is fully queryable via the diff helper too.
      assert {:ok, diff} = Cap.diff_versions(alert.id, 2, 3)
      fields = CapAlertWorkbench.Cap.VersionDiff.changed_fields(diff)
      assert Enum.any?(fields, &(&1.field == "msg_type" and &1.after_value == "cancel"))
    end

    test "is idempotent: a repeated request returns the existing version with no extra audit/outbox" do
      alert = publish_initial()

      assert {:ok, first} = Cap.create_cancellation_c2(alert.id, "publisher-1")
      first_version = first.new_version.version

      assert {:ok, second} = Cap.create_cancellation_c2(alert.id, "publisher-2")
      assert second.idempotent == true
      assert second.version.id == first_version.id
      assert second.new_version.version.id == first_version.id

      # Still exactly three versions; no fourth version was created.
      versions = Repo.all(from v in Version, where: v.alert_id == ^alert.id)
      assert length(versions) == 3

      # Exactly one cancellation audit event and one canceled outbox message.
      cancellation_audits =
        Repo.all(
          from e in AuditEvent,
            where: e.alert_id == ^alert.id and e.action == "cancellation_created"
        )

      assert length(cancellation_audits) == 1

      canceled_outbox =
        Repo.all(
          from o in OutboxMessage,
            where: o.alert_id == ^alert.id and o.topic == "alert.canceled"
        )

      assert length(canceled_outbox) == 1
    end

    test "records an audit event for every state transition" do
      alert = publish_initial()
      {:ok, _} = Cap.create_cancellation_c2(alert.id, "publisher")

      actions =
        alert.id
        |> Cap.list_audit_events()
        |> Enum.map(& &1.action)

      assert "cancellation_created" in actions

      # The supersede/insert happen in one transaction; the cancellation audit
      # references version 3.
      audit =
        Repo.one!(
          from e in AuditEvent,
            where: e.alert_id == ^alert.id and e.action == "cancellation_created"
        )

      assert audit.metadata["version_number"] == 3
    end

    test "concurrent duplicate cancellations cannot create two C2 versions or outbox rows" do
      alert = publish_initial()
      parent = self()

      tasks =
        Enum.map(1..2, fn i ->
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(CapAlertWorkbench.Repo, parent, self())

            result = Cap.create_cancellation_c2(alert.id, "publisher-#{i}")
            send(parent, {:c2, i, result})
          end)
        end)

      Enum.each(tasks, &Task.await(&1, 5000))

      results =
        for _ <- 1..2 do
          receive do
            {:c2, _i, result} -> result
          after
            2000 -> flunk("C2 did not complete")
          end
        end

      # Both callables receive an :ok (the second is the idempotent replay),
      # but only one C2 version and one canceled outbox row exist.
      assert Enum.all?(results, &match?({:ok, _}, &1))

      versions = Repo.all(from v in Version, where: v.alert_id == ^alert.id)
      assert length(versions) == 3

      outbox =
        Repo.aggregate(
          from(o in OutboxMessage,
            where: o.alert_id == ^alert.id and o.topic == "alert.canceled"
          ),
          :count
        )

      assert outbox == 1
    end

    test "cannot create C2 twice with different identifiers; C1 itself still rejects duplicates" do
      alert = publish_initial()
      assert {:ok, _} = Cap.create_cancellation_c2(alert.id, "publisher")

      # After cancellation the alert is terminal; a generic correction is rejected.
      assert {:error, {:invalid_status, :canceled}} =
               Cap.create_correction(alert.id, %{"headline" => "x"}, "publisher")
    end
  end
end
