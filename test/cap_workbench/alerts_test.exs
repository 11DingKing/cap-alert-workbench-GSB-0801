defmodule CapWorkbench.AlertsTest do
  use CapWorkbench.DataCase, async: true

  alias CapWorkbench.Alerts
  alias CapWorkbench.Cap.{AuditEvent, OutboxEntry}

  import CapWorkbench.AlertsFixtures
  import Ecto.Query

  describe "create_message/2" do
    test "creates message + first immutable version + audit event" do
      assert {:ok, message} = Alerts.create_message(valid_attrs(), "值班员")
      assert message.workflow_state == :drafting
      assert message.lock_version == 1
      assert [version] = message.versions
      assert version.version_number == 1
      assert version.review_state == :pending

      assert [%AuditEvent{action: :draft_created}] = Alerts.list_audit_events(message)
    end

    test "rejects invalid geocodes" do
      assert {:error, changeset} = Alerts.create_message(valid_attrs(%{geocodes: ["44"]}), "x")
      assert %{geocodes: [_ | _]} = errors_on(changeset)
    end
  end

  describe "save_new_version/4 (edit)" do
    test "creates a new immutable version and never mutates the old one" do
      message = message_fixture()
      [v1] = message.versions

      assert {:ok, message} =
               Alerts.save_new_version(message, %{"headline" => "更新后的标题"}, message.lock_version)

      versions = message.versions
      assert length(versions) == 2
      assert Enum.map(versions, & &1.version_number) == [1, 2]

      reloaded_v1 = Alerts.get_version!(v1.id)
      assert reloaded_v1.headline == v1.headline
      assert List.last(versions).headline == "更新后的标题"
    end

    test "optimistic lock: the second concurrent writer loses with :stale" do
      message = message_fixture()
      stale_lock = message.lock_version

      # First writer wins.
      assert {:ok, updated} =
               Alerts.save_new_version(message, %{"headline" => "writer A"}, stale_lock)

      refute updated.lock_version == stale_lock

      # Second writer used the SAME (now stale) lock version -> conflict.
      assert {:error, :stale} =
               Alerts.save_new_version(message, %{"headline" => "writer B"}, stale_lock)

      # Only writer A's version was persisted (plus the original) = 2 total.
      reloaded = Alerts.get_message!(message.id)
      assert length(reloaded.versions) == 2
    end
  end

  describe "review/6 stale detection" do
    setup do
      message = message_fixture()
      v = Alerts.latest_version(message)
      {:ok, message} = Alerts.submit_for_review(message, v, message.lock_version)
      %{message: message}
    end

    test "approve works on the version under review", %{message: message} do
      v = Alerts.latest_version(message)

      assert {:ok, message} =
               Alerts.review(message, v, :approve, "复核员", "ok", message.lock_version)

      assert message.workflow_state == :in_review
      assert Alerts.latest_version(message).review_state == :approved
    end

    test "a review decision on a superseded version is rejected as stale", %{message: message} do
      old_version = Alerts.latest_version(message)

      # A new draft is saved while review is pending; message drops to drafting
      # and old_version is no longer the one to act on.
      {:ok, message} =
        Alerts.save_new_version(message, %{"headline" => "新草稿抢占"}, message.lock_version)

      # Reviewer still holds the OLD version and tries to approve it.
      assert {:error, :stale_review} =
               Alerts.review(message, old_version, :approve, "复核员", nil, message.lock_version)

      # State remains drafting; nothing approved.
      reloaded = Alerts.get_message!(message.id)
      assert reloaded.workflow_state == :drafting
      refute Enum.any?(reloaded.versions, &(&1.review_state == :approved))
    end
  end

  describe "publish/4" do
    test "publishes an approved latest version exactly once, with outbox + audit" do
      message = published_message_fixture()
      assert message.workflow_state == :published
      version = Alerts.latest_version(message)
      assert version.published

      assert [%OutboxEntry{event_type: :published, status: :pending}] =
               Alerts.list_outbox_entries(message)

      actions = Alerts.list_audit_events(message) |> Enum.map(& &1.action)
      assert :published in actions
    end

    test "duplicate publish is rejected (already published)" do
      message = published_message_fixture()
      version = Alerts.latest_version(message)

      assert {:error, :already_published} =
               Alerts.publish(message, version, message.lock_version)

      # Still exactly one outbox entry.
      assert length(Alerts.list_outbox_entries(message)) == 1
    end

    test "cannot publish a non-approved version" do
      message = message_fixture()
      v = Alerts.latest_version(message)
      {:ok, message} = Alerts.submit_for_review(message, v, message.lock_version)
      v = Alerts.latest_version(message)

      assert {:error, :not_publishable} = Alerts.publish(message, v, message.lock_version)
    end
  end

  describe "publish transaction atomicity" do
    test "a duplicate outbox key rolls back the entire publish (no partial state)" do
      message = message_fixture()
      v = Alerts.latest_version(message)
      {:ok, message} = Alerts.submit_for_review(message, v, message.lock_version)
      v = Alerts.latest_version(message)
      {:ok, message} = Alerts.review(message, v, :approve, "复核员", nil, message.lock_version)
      version = Alerts.latest_version(message)

      # Pre-insert an outbox row with the SAME dedupe key publish would use,
      # forcing the unique constraint to fire inside the publish transaction.
      Repo.insert!(%OutboxEntry{
        alert_message_id: message.id,
        draft_version_id: version.id,
        event_type: :published,
        status: :pending,
        dedupe_key: "publish:" <> version.id,
        payload_xml: "<pre-existing/>"
      })

      assert {:error, :duplicate_publish} =
               Alerts.publish(message, version, message.lock_version)

      # Everything rolled back: message not published, version not frozen,
      # no extra audit event, still exactly the one pre-existing outbox row.
      reloaded = Alerts.get_message!(message.id)
      assert reloaded.workflow_state == :in_review
      assert reloaded.published_version_id == nil
      refute Alerts.latest_version(reloaded).published

      refute Enum.any?(Alerts.list_audit_events(reloaded), &(&1.action == :published))

      assert Repo.aggregate(
               from(o in OutboxEntry, where: o.alert_message_id == ^message.id),
               :count
             ) == 1
    end
  end

  describe "corrections and cancellations" do
    test "correction derives a new :update message referencing the published one" do
      published = published_message_fixture()

      assert {:ok, correction} =
               Alerts.create_correction(published, %{headline: "更正：升级为红色"}, "值班员")

      assert correction.msg_type == :update
      assert correction.references_message_id == published.id
      assert correction.references_text =~ published.identifier
      assert correction.workflow_state == :drafting
      assert Alerts.latest_version(correction).headline == "更正：升级为红色"
    end

    test "cancellation derives a new :cancel message" do
      published = published_message_fixture()
      assert {:ok, cancel} = Alerts.create_cancellation(published, %{}, "值班员")
      assert cancel.msg_type == :cancel
      assert cancel.references_message_id == published.id
    end

    test "cannot correct a draft (not published)" do
      message = message_fixture()
      assert {:error, :not_published} = Alerts.create_correction(message, %{}, "x")
    end

    test "publishing a correction supersedes its predecessor atomically" do
      published = published_message_fixture()
      {:ok, correction} = Alerts.create_correction(published, %{headline: "更正稿"}, "值班员")

      v = Alerts.latest_version(correction)
      {:ok, correction} = Alerts.submit_for_review(correction, v, correction.lock_version)
      v = Alerts.latest_version(correction)

      {:ok, correction} =
        Alerts.review(correction, v, :approve, "复核员", nil, correction.lock_version)

      v = Alerts.latest_version(correction)
      {:ok, correction} = Alerts.publish(correction, v, correction.lock_version)

      assert correction.workflow_state == :published

      # Predecessor is now superseded.
      reloaded_predecessor = Alerts.get_message!(published.id)
      assert reloaded_predecessor.workflow_state == :superseded
    end
  end

  describe "content immutability of published messages" do
    test "a published message cannot be edited via save_new_version" do
      message = published_message_fixture()

      assert {:error, :not_editable} =
               Alerts.save_new_version(message, %{"headline" => "偷偷改"}, message.lock_version)
    end
  end

  describe "diff_versions/2" do
    test "flags changed fields between two versions" do
      message = message_fixture()

      {:ok, message} =
        Alerts.save_new_version(message, %{"headline" => "改了标题"}, message.lock_version)

      [v1, v2] = message.versions

      diff = Alerts.diff_versions(v1, v2)
      headline_row = Enum.find(diff, &(&1.field == :headline))
      assert headline_row.changed?
      assert headline_row.to == "改了标题"

      event_row = Enum.find(diff, &(&1.field == :event))
      refute event_row.changed?
    end
  end
end
