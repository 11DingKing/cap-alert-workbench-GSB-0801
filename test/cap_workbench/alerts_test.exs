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
      attrs = valid_attrs(%{infos: [valid_info(%{"geocodes" => ["44"]})]})
      assert {:error, changeset} = Alerts.create_message(attrs, "x")
      refute changeset.valid?
    end
  end

  # Replaces the single info block's headline via save_new_version.
  defp edit_headline(message, headline) do
    latest = Alerts.latest_version(message)
    info = hd(latest.infos)
    infos = [Map.merge(Alerts.info_to_map(info), %{"headline" => headline})]
    Alerts.save_new_version(message, %{"infos" => infos}, message.lock_version)
  end

  describe "save_new_version/4 (edit)" do
    test "creates a new immutable version and never mutates the old one" do
      message = message_fixture()
      [v1] = message.versions
      v1_headline = hd(v1.infos).headline

      assert {:ok, message} = edit_headline(message, "更新后的标题")

      versions = message.versions
      assert length(versions) == 2
      assert Enum.map(versions, & &1.version_number) == [1, 2]

      reloaded_v1 = Alerts.get_version!(v1.id)
      assert hd(reloaded_v1.infos).headline == v1_headline
      assert hd(List.last(versions).infos).headline == "更新后的标题"
    end

    test "optimistic lock: the second concurrent writer loses with :stale" do
      message = message_fixture()
      stale_lock = message.lock_version
      info_map = Alerts.info_to_map(hd(Alerts.latest_version(message).infos))

      # First writer wins.
      assert {:ok, updated} =
               Alerts.save_new_version(
                 message,
                 %{"infos" => [Map.put(info_map, "headline", "writer A")]},
                 stale_lock
               )

      refute updated.lock_version == stale_lock

      # Second writer used the SAME (now stale) lock version -> conflict.
      assert {:error, :stale} =
               Alerts.save_new_version(
                 message,
                 %{"infos" => [Map.put(info_map, "headline", "writer B")]},
                 stale_lock
               )

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
      {:ok, message} = edit_headline(message, "新草稿抢占")

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
    test "correction derives a new :update message referencing the published one exactly" do
      published = published_message_fixture()

      assert {:ok, correction} = Alerts.create_correction(published, %{}, "值班员")

      assert correction.msg_type == :update
      assert correction.identifier == published.identifier <> "-C1"
      assert correction.references_message_id == published.id
      # references text points exactly at the source (sender,identifier,sent).
      assert correction.references_text =~ published.identifier
      assert correction.references_text =~ published.sender
      assert correction.workflow_state == :drafting
    end

    test "per-region correction: 440900 -> Extreme while 440800 stays Severe" do
      # Seed a single info covering both regions at Severe, publish it.
      published = published_message_fixture()

      assert {:ok, correction} =
               Alerts.create_correction(
                 published,
                 %{region_severities: %{"440900" => :extreme}},
                 "值班员"
               )

      infos = Alerts.latest_version(correction).infos

      by_geocode =
        Enum.flat_map(infos, fn info ->
          Enum.map(info.geocodes, fn geo -> {geo, info.severity} end)
        end)
        |> Map.new()

      assert by_geocode["440800"] == :severe
      assert by_geocode["440900"] == :extreme
      # The two regions must be carried in distinct info blocks.
      assert length(infos) == 2
    end

    test "cancellation derives a new :cancel message" do
      published = published_message_fixture()
      assert {:ok, cancel} = Alerts.create_cancellation(published, %{}, "值班员")
      assert cancel.msg_type == :cancel
      # First derivation in the chain, regardless of type, is -C1.
      assert cancel.identifier == published.identifier <> "-C1"
      assert cancel.references_message_id == published.id
    end

    test "cannot correct a draft (not published)" do
      message = message_fixture()
      assert {:error, :not_published} = Alerts.create_correction(message, %{}, "x")
    end

    test "creating a correction is idempotent: repeated calls return the same C1" do
      published = published_message_fixture()

      assert {:ok, c1a} =
               Alerts.create_correction(
                 published,
                 %{region_severities: %{"440900" => :extreme}},
                 "值班员"
               )

      assert {:ok, c1b} =
               Alerts.create_correction(
                 published,
                 %{region_severities: %{"440900" => :extreme}},
                 "值班员"
               )

      # Same row, not a second C1.
      assert c1a.id == c1b.id
      assert c1a.identifier == published.identifier <> "-C1"

      # Exactly one correction exists in the database.
      import Ecto.Query
      alias CapWorkbench.Cap.AlertMessage

      count =
        Repo.aggregate(
          from(m in AlertMessage, where: m.references_message_id == ^published.id),
          :count
        )

      assert count == 1
    end

    test "publishing a correction supersedes its predecessor atomically" do
      published = published_message_fixture()

      {:ok, correction} =
        Alerts.create_correction(published, %{region_severities: %{"440900" => :extreme}}, "值班员")

      v = Alerts.latest_version(correction)
      {:ok, correction} = Alerts.submit_for_review(correction, v, correction.lock_version)
      v = Alerts.latest_version(correction)

      {:ok, correction} =
        Alerts.review(correction, v, :approve, "复核员", nil, correction.lock_version)

      v = Alerts.latest_version(correction)
      {:ok, correction} = Alerts.publish(correction, v, correction.lock_version)

      assert correction.workflow_state == :published

      # Publishing produces exactly one outbox entry for the correction.
      assert length(Alerts.list_outbox_entries(correction)) == 1

      # Predecessor is now superseded.
      reloaded_predecessor = Alerts.get_message!(published.id)
      assert reloaded_predecessor.workflow_state == :superseded
    end
  end

  describe "cancellation referencing a published correction (CN-...-C2)" do
    # Drives a derived draft (correction/cancellation) all the way to published.
    defp publish_derived(message) do
      v = Alerts.latest_version(message)
      {:ok, message} = Alerts.submit_for_review(message, v, message.lock_version, "值班员")
      v = Alerts.latest_version(message)
      {:ok, message} = Alerts.review(message, v, :approve, "复核员", nil, message.lock_version)
      v = Alerts.latest_version(message)
      {:ok, message} = Alerts.publish(message, v, message.lock_version, "值班员")
      message
    end

    test "cancel of published C1 gets -C2, references C1 exactly, and keeps its multi-info parse" do
      # Round 1: publish the original alert.
      original = published_message_fixture()

      # Round 2: correction C1 lifts 440900 to Extreme while 440800 stays Severe,
      # then publish it so it becomes the latest published document.
      {:ok, c1} =
        Alerts.create_correction(
          original,
          %{region_severities: %{"440900" => :extreme}},
          "值班员"
        )

      assert c1.identifier == original.identifier <> "-C1"
      c1 = publish_derived(c1)
      assert c1.workflow_state == :published

      # Round 4: cancellation derived from the published C1.
      {:ok, c2} = Alerts.create_cancellation(c1, %{}, "值班员")

      assert c2.msg_type == :cancel
      # Next link in the same chain, so -C2 (not -C1 nor -X1).
      assert c2.identifier == original.identifier <> "-C2"
      # References the published C1 exactly.
      assert c2.references_message_id == c1.id
      assert c2.references_text =~ c1.identifier
      assert c2.references_text =~ c1.sender

      # The cancellation preserves C1's verified multi-info parse: both regions,
      # each with its own severity, carried in two distinct info blocks.
      infos = Alerts.latest_version(c2).infos
      assert length(infos) == 2

      by_geocode =
        infos
        |> Enum.flat_map(fn info -> Enum.map(info.geocodes, &{&1, info.severity}) end)
        |> Map.new()

      assert by_geocode["440800"] == :severe
      assert by_geocode["440900"] == :extreme
    end

    test "creating the C2 cancellation is idempotent" do
      original = published_message_fixture()

      {:ok, c1} =
        Alerts.create_correction(original, %{region_severities: %{"440900" => :extreme}}, "值班员")

      c1 = publish_derived(c1)

      assert {:ok, c2a} = Alerts.create_cancellation(c1, %{}, "值班员")
      assert {:ok, c2b} = Alerts.create_cancellation(c1, %{}, "值班员")

      # Same row, not a second cancellation.
      assert c2a.id == c2b.id
      assert c2a.identifier == original.identifier <> "-C2"

      alias CapWorkbench.Cap.AlertMessage

      count =
        Repo.aggregate(
          from(m in AlertMessage, where: m.references_message_id == ^c1.id),
          :count
        )

      assert count == 1
    end

    test "the full version chain remains viewable after cancellation" do
      original = published_message_fixture()

      {:ok, c1} =
        Alerts.create_correction(original, %{region_severities: %{"440900" => :extreme}}, "值班员")

      c1 = publish_derived(c1)
      {:ok, c2} = Alerts.create_cancellation(c1, %{}, "值班员")
      c2 = publish_derived(c2)

      # After cancellation, C1 is superseded but still exists in the chain.
      assert Alerts.get_message!(c1.id).workflow_state == :superseded

      chain = Alerts.message_chain(c2)

      identifiers = Enum.map(chain, & &1.identifier)

      assert identifiers == [
               original.identifier,
               original.identifier <> "-C1",
               original.identifier <> "-C2"
             ]

      # Every link still carries its immutable versions.
      assert Enum.all?(chain, fn m -> m.versions != [] end)
      # The chain can be reached from any of its members.
      assert Alerts.message_chain(original) == chain
    end

    test "every state transition is audited across the whole chain" do
      original = published_message_fixture()

      {:ok, c1} =
        Alerts.create_correction(original, %{region_severities: %{"440900" => :extreme}}, "值班员")

      c1 = publish_derived(c1)
      {:ok, c2} = Alerts.create_cancellation(c1, %{}, "值班员")
      c2 = publish_derived(c2)

      original_actions = Enum.map(Alerts.list_audit_events(original), & &1.action)
      c1_actions = Enum.map(Alerts.list_audit_events(c1), & &1.action)
      c2_actions = Enum.map(Alerts.list_audit_events(c2), & &1.action)

      # Original: created → submitted → approved → published → superseded (by C1).
      assert original_actions == [
               :draft_created,
               :submitted_for_review,
               :approved,
               :published,
               :superseded
             ]

      # C1: created as correction → submitted → approved → published → superseded (by C2).
      assert c1_actions == [
               :correction_created,
               :submitted_for_review,
               :approved,
               :published,
               :superseded
             ]

      # C2: created as cancellation → submitted → approved → published.
      assert c2_actions == [
               :cancellation_created,
               :submitted_for_review,
               :approved,
               :published
             ]
    end
  end

  describe "content immutability of published messages" do
    test "a published message cannot be edited via save_new_version" do
      message = published_message_fixture()
      info_map = Alerts.info_to_map(hd(Alerts.latest_version(message).infos))

      assert {:error, :not_editable} =
               Alerts.save_new_version(
                 message,
                 %{"infos" => [Map.put(info_map, "headline", "偷偷改")]},
                 message.lock_version
               )
    end
  end

  describe "diff_versions/2 (per region)" do
    test "reports per-region status and changes" do
      # v1: both regions Severe in one block. v2: split so 440900 -> Extreme.
      message = message_fixture()
      source_info = Alerts.info_to_map(hd(Alerts.latest_version(message).infos))

      infos_v2 = [
        Map.merge(source_info, %{"geocodes" => ["440800"], "severity" => "severe"}),
        Map.merge(source_info, %{
          "geocodes" => ["440900"],
          "severity" => "extreme",
          "headline" => "茂名升级"
        })
      ]

      {:ok, message} =
        Alerts.save_new_version(message, %{"infos" => infos_v2}, message.lock_version)

      [v1, v2] = message.versions

      diff = Alerts.diff_versions(v1, v2)

      row_800 = Enum.find(diff, &(&1.geocode == "440800"))
      row_900 = Enum.find(diff, &(&1.geocode == "440900"))

      assert row_800.status == :unchanged
      assert row_900.status == :changed
      assert Enum.any?(row_900.changes, &(&1.field == :severity and &1.to == :extreme))
    end
  end
end
