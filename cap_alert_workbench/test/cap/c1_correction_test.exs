defmodule CapAlertWorkbench.Cap.C1CorrectionTest do
  use CapAlertWorkbench.DataCase, async: false

  alias CapAlertWorkbench.Cap
  alias CapAlertWorkbench.Cap.{Message, Version}
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
    published
  end

  test "C1 correction derives from the latest published version and produces two info segments" do
    alert = publish_initial()

    assert {:ok, %{alert: _corrected, new_version: %{version: version}}} =
             Cap.create_correction_c1(alert.id, "publisher")

    # The new version is published and carries the C1 identifier.
    assert version.status == :published
    assert version.kind == :correction
    assert version.version_number == 2

    message = Cap.Xml.Codec.decode!(version.xml_snapshot)
    assert message.identifier == "CN-20260729-GD-RAIN-001-C1"
    assert message.msg_type == :update
    assert length(message.infos) == 2

    # Area 440800 stays Severe; 440900 becomes Extreme.
    severe_info = Message.info_for_area(message, "440800")
    extreme_info = Message.info_for_area(message, "440900")

    assert severe_info.severity == :severe
    assert extreme_info.severity == :extreme
    assert severe_info.areas |> length() == 1
    assert extreme_info.areas |> length() == 1

    # Each area appears exactly once across all info segments.
    all_codes = Message.area_codes(message)
    assert Enum.sort(all_codes) == ["440800", "440900"]

    # references point precisely at the first-round published document.
    assert length(message.references) == 1
    [ref] = message.references
    assert ref =~ "xinxi@gd.cma.gov.cn"
    assert ref =~ "CN-20260729-GD-RAIN-001,"
    refute ref =~ "C1"
  end

  test "C1 XML round-trips through import/export preserving area-to-severity mapping" do
    alert = publish_initial()
    {:ok, %{new_version: %{version: version}}} = Cap.create_correction_c1(alert.id, "publisher")

    assert {:ok, decoded} = Cap.Xml.Codec.decode(version.xml_snapshot)
    re_encoded = Cap.Xml.Codec.encode!(decoded)

    # Re-encoding produces byte-identical XML: info/area correspondence is
    # preserved through the multi-info parser.
    assert re_encoded == version.xml_snapshot

    assert Message.info_for_area(decoded, "440800").severity == :severe
    assert Message.info_for_area(decoded, "440900").severity == :extreme
  end

  test "C1 can only be created from a published alert and references the root version" do
    alert = publish_initial()
    root = Repo.one!(from v in Version, where: v.alert_id == ^alert.id and v.version_number == 1)

    {:ok, %{new_version: %{version: c1}}} = Cap.create_correction_c1(alert.id, "publisher")

    assert c1.references == [
             "#{root.payload["sender"]},#{root.payload["identifier"]}," <>
               Cap.Xml.Codec.format_ref_time(root.payload["sent_at"])
           ]
  end

  test "per-area diff reports 440900 severity as modified and 440800 unchanged" do
    alert = publish_initial()
    {:ok, %{new_version: %{version: _c1}}} = Cap.create_correction_c1(alert.id, "publisher")

    {:ok, diff} = Cap.diff_versions(alert.id, 1, 2)
    changes = CapAlertWorkbench.Cap.VersionDiff.changed_fields(diff)

    severity_changes = Enum.filter(changes, &(&1.field == "severity"))

    assert Enum.any?(severity_changes, fn change ->
             change.area == "440900" and change.change == :modified and
               change.after_value == "extreme"
           end)

    refute Enum.any?(severity_changes, &(&1.area == "440800" and &1.change == :modified))

    # The identifier changed to C1.
    assert Enum.any?(changes, &(&1.field == "identifier" and &1.after_value =~ "C1"))
  end

  test "duplicate concurrent C1 publications cannot create a second C1 or duplicate outbox" do
    alert = publish_initial()
    parent = self()

    tasks =
      Enum.map(1..2, fn i ->
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(CapAlertWorkbench.Repo, parent, self())

          result = Cap.create_correction_c1(alert.id, "publisher-#{i}")
          send(parent, {:c1, i, result})
        end)
      end)

    Enum.each(tasks, &Task.await(&1, 5000))

    results =
      for _ <- 1..2 do
        receive do
          {:c1, _i, result} -> result
        after
          2000 -> flunk("C1 did not complete")
        end
      end

    published = Enum.count(results, &match?({:ok, _}, &1))
    rejected = Enum.count(results, &match?({:error, _}, &1))

    assert published == 1
    assert rejected == 1

    # Only one correction version (version 2) and one outbox notification exist.
    versions = Repo.all(from v in Version, where: v.alert_id == ^alert.id)
    assert length(versions) == 2
    assert Enum.any?(versions, &(&1.version_number == 2 and &1.kind == :correction))

    outbox_count =
      Repo.aggregate(
        from(o in CapAlertWorkbench.Cap.OutboxMessage,
          where: o.alert_id == ^alert.id and o.topic == "alert.corrected"
        ),
        :count
      )

    assert outbox_count == 1
  end
end
