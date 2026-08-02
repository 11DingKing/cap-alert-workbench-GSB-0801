defmodule CapAlertWorkbench.CapAlert.AlertsTest do
  use CapAlertWorkbench.DataCase, async: false

  alias CapAlertWorkbench.CapAlert
  alias CapAlertWorkbench.CapAlert.{AuditEvent, NotificationOutbox}

  @identifier "CN-20260729-GD-RAIN-001"

  @initial_attrs %{
    "identifier" => @identifier,
    "sender" => "duty-officer@gd.example",
    "sent" => ~U[2026-07-29 08:00:00Z],
    "status" => "actual",
    "msg_type" => "alert",
    "scope" => "public",
    "infos" => %{
      "0" => %{
        "language" => "zh-CN",
        "event" => "暴雨",
        "headline" => "暴雨红色预警",
        "description" => "预计未来6小时降雨量将达100毫米以上",
        "instruction" => "停止集会、停课、停业",
        "urgency" => "immediate",
        "severity" => "severe",
        "certainty" => "likely",
        "area_desc" => "湛江市、茂名市",
        "geocodes" => %{
          "0" => %{"value_name" => "Same", "value" => "440800"},
          "1" => %{"value_name" => "Same", "value" => "440900"}
        }
      }
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

  defp publish_chain!(version) do
    version |> submit!() |> approve!() |> publish!()
  end

  defp count(query), do: CapAlertWorkbench.Repo.aggregate(query, :count)

  defp info(version, idx \\ 0), do: Enum.at(version.infos, idx)

  describe "create_alert/2" do
    test "creates the initial draft with one info covering two regions" do
      {alert, version} = create_alert!()

      assert alert.identifier == @identifier
      assert alert.latest_version_id == version.id
      assert version.version_number == 1
      assert version.workflow_state == :draft
      assert version.status == :actual
      assert version.msg_type == :alert
      assert version.scope == :public
      assert length(version.infos) == 1

      info = info(version)
      assert info.language == "zh-CN"
      assert info.event == "暴雨"
      assert info.urgency == :immediate
      assert info.severity == :severe
      assert info.certainty == :likely
      assert Enum.map(info.geocodes, & &1.value) == ["440800", "440900"]

      audit = CapAlert.list_audit_events(alert.identifier)
      assert Enum.any?(audit, &(&1.action == "created"))
    end

    test "supports multiple info segments with independent severity per region" do
      attrs = %{
        "identifier" => "CN-MULTI-001",
        "sender" => "s@example.com",
        "sent" => ~U[2026-07-29 08:00:00Z],
        "status" => "actual",
        "msg_type" => "alert",
        "scope" => "public",
        "infos" => %{
          "0" => %{
            "event" => "暴雨",
            "severity" => "severe",
            "geocodes" => %{"0" => %{"value_name" => "Same", "value" => "440800"}}
          },
          "1" => %{
            "event" => "暴雨",
            "severity" => "extreme",
            "geocodes" => %{"0" => %{"value_name" => "Same", "value" => "440900"}}
          }
        }
      }

      {:ok, %{version: version}} = CapAlert.create_alert(attrs, "t")
      assert length(version.infos) == 2
      assert Enum.at(version.infos, 0).severity == :severe
      assert Enum.at(version.infos, 1).severity == :extreme
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
        CapAlert.edit_draft(
          version,
          %{
            "infos" => %{
              "0" => %{
                "event" => "暴雨",
                "headline" => "新标题",
                "severity" => "severe",
                "geocodes" => %{
                  "0" => %{"value_name" => "Same", "value" => "440800"},
                  "1" => %{"value_name" => "Same", "value" => "440900"}
                }
              }
            },
            "lock_version" => 1
          },
          "editor"
        )

      assert hd(updated.infos).headline == "新标题"
      assert updated.lock_version == 2

      audit = CapAlert.list_audit_events(version.alert_identifier)
      assert Enum.any?(audit, &(&1.action == "edited"))
    end

    test "returns :stale when lock_version does not match (optimistic lock)" do
      {_alert, version} = create_alert!()

      {:ok, _} =
        CapAlert.edit_draft(
          version,
          %{"headline" => "A", "lock_version" => 1, "infos" => infos_param(version.infos)},
          "browser-1"
        )

      assert {:error, :stale} =
               CapAlert.edit_draft(
                 version,
                 %{"headline" => "B", "lock_version" => 1, "infos" => infos_param(version.infos)},
                 "browser-2"
               )
    end

    test "cannot edit a published version" do
      {_alert, version} = create_alert!()
      published = publish_chain!(version)

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
      assert published.xml_payload =~ @identifier
      assert published.xml_payload =~ "440800"
      assert published.xml_payload =~ "440900"

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

      {:ok, edited} =
        CapAlert.edit_draft(
          rejected,
          %{
            "infos" => infos_param(rejected.infos),
            "lock_version" => rejected.lock_version
          },
          "editor"
        )

      assert edited.workflow_state == :changes_requested
    end

    test "stale review is rejected after a newer draft is created" do
      {_alert, version} = create_alert!()
      submitted = submit!(version)

      {:ok, new_draft} = CapAlert.revise(submitted, "author")
      assert new_draft.version_number == 2
      assert new_draft.workflow_state == :draft

      assert {:error, :stale_review} =
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

      reloaded = CapAlert.get_version!(version.id)
      assert reloaded.workflow_state == :approved
      assert reloaded.published_at == nil

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

  describe "same-alert correction and cancellation" do
    setup do
      {_alert, version} = create_alert!()
      published = publish_chain!(version)
      %{published: published}
    end

    test "create_correction produces an Update draft referencing the published version", %{
      published: p
    } do
      assert {:ok, correction} =
               CapAlert.create_correction(
                 %{"alert_identifier" => p.alert_identifier},
                 "editor"
               )

      assert correction.msg_type == :update
      assert correction.workflow_state == :draft
      assert correction.based_on_version_id == p.id
      assert correction.references =~ p.alert_identifier
      assert correction.references =~ p.sender
      assert length(correction.infos) == length(p.infos)

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
                 %{"alert_identifier" => p.alert_identifier},
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

  describe "C1 correction as a new alert aggregate" do
    setup do
      {_alert, version} = create_alert!()
      published = publish_chain!(version)
      %{published: published}
    end

    test "creates CN-...-C1 with two infos: 440800 stays Severe, 440900 becomes Extreme", %{
      published: p
    } do
      assert {:ok, %{alert: c1_alert, version: c1}} =
               CapAlert.create_correction_alert(
                 %{"source_identifier" => p.alert_identifier},
                 "editor"
               )

      assert c1_alert.identifier == "#{p.alert_identifier}-C1"
      assert c1.msg_type == :update
      assert c1.status == :actual
      assert c1.workflow_state == :draft
      assert c1.based_on_version_id == p.id

      assert length(c1.infos) == 2

      by_region = Map.new(c1.infos, fn info -> {hd(info.geocodes).value, info} end)
      assert by_region["440800"].severity == :severe
      assert by_region["440900"].severity == :extreme
      assert by_region["440900"].area_desc == "440900"
    end

    test "references precisely point to the first-round published document", %{published: p} do
      assert {:ok, %{version: c1}} =
               CapAlert.create_correction_alert(
                 %{"source_identifier" => p.alert_identifier},
                 "editor"
               )

      first_round = CapAlert.first_published_version(p.alert_identifier)
      assert first_round.id == p.id

      assert c1.references ==
               "#{p.sender},#{p.alert_identifier},#{DateTime.to_iso8601(p.sent)}"
    end

    test "cannot create C1 without a published source version" do
      {:ok, %{alert: alert}} =
        CapAlert.create_alert(%{@initial_attrs | "identifier" => "CN-NOPUB-003"}, "t")

      assert {:error, :no_published_version} =
               CapAlert.create_correction_alert(
                 %{"source_identifier" => alert.identifier},
                 "t"
               )
    end

    test "duplicate concurrent C1 creation produces only one alert and no duplicate outbox", %{
      published: p
    } do
      parent = self()
      ref = make_ref()

      tasks =
        for i <- 1..2 do
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(CapAlertWorkbench.Repo, parent, self())

            result =
              CapAlert.create_correction_alert(
                %{"source_identifier" => p.alert_identifier},
                "c1-browser-#{i}"
              )

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
            5_000 -> flunk("timeout waiting for c1 result")
          end
        end

      success = Enum.filter(results, &match?({:ok, _}, &1))
      failures = Enum.filter(results, &match?({:error, _}, &1))

      assert length(success) == 1
      assert length(failures) == 1

      c1_id = "#{p.alert_identifier}-C1"
      assert CapAlert.get_alert(c1_id) != nil

      c1_versions = CapAlert.list_versions(c1_id)
      assert length(c1_versions) == 1

      assert count(
               from a in AuditEvent,
                 where: a.alert_identifier == ^c1_id and a.action == "c1_created"
             ) == 1

      assert count(from o in NotificationOutbox, where: o.alert_identifier == ^c1_id) == 0
    end

    test "C1 can be reviewed and published; it emits exactly one outbox", %{published: p} do
      assert {:ok, %{version: c1}} =
               CapAlert.create_correction_alert(
                 %{"source_identifier" => p.alert_identifier},
                 "editor"
               )

      {:ok, submitted} = CapAlert.submit_for_review(c1, "editor")
      {:ok, approved} = CapAlert.review(submitted, :approve, "ok", "reviewer")
      assert {:ok, published_c1} = CapAlert.publish(approved, "publisher")
      assert published_c1.workflow_state == :published

      outbox = CapAlert.list_outbox("#{p.alert_identifier}-C1")
      assert length(outbox) == 1
      assert hd(outbox).event_type == "alert.update"

      xml = published_c1.xml_payload
      assert xml =~ ~r(<msgType>\s*Update\s*</msgType>)
      assert xml =~ "<references>"
      assert xml =~ "440800"
      assert xml =~ "440900"
      assert xml =~ ~r(<severity>\s*Extreme\s*</severity>)
      assert xml =~ ~r(<severity>\s*Severe\s*</severity>)
    end

    test "per-region diff shows combined region removed and two single regions added", %{
      published: p
    } do
      assert {:ok, %{version: c1}} =
               CapAlert.create_correction_alert(
                 %{"source_identifier" => p.alert_identifier},
                 "editor"
               )

      diff = CapAlert.diff_versions(p, c1)
      keys = Enum.map(diff.regions, & &1.key) |> Enum.sort()
      assert "440800" in keys
      assert "440900" in keys
      assert "440800,440900" in keys

      combined = Enum.find(diff.regions, &(&1.key == "440800,440900"))
      assert combined.status == :removed

      new_440900 = Enum.find(diff.regions, &(&1.key == "440900"))
      assert new_440900.status == :added
      assert new_440900.new_info.severity == :extreme

      new_440800 = Enum.find(diff.regions, &(&1.key == "440800"))
      assert new_440800.status == :added
      assert new_440800.new_info.severity == :severe
    end
  end

  describe "version diff (per region)" do
    test "detects changed fields within the same region" do
      {_alert, v1} = create_alert!()

      {:ok, v2} =
        CapAlert.edit_draft(
          v1,
          %{
            "infos" => %{
              "0" => %{
                "event" => "暴雨",
                "headline" => "变更后标题",
                "severity" => "severe",
                "geocodes" => %{
                  "0" => %{"value_name" => "Same", "value" => "440800"},
                  "1" => %{"value_name" => "Same", "value" => "440900"}
                }
              }
            }
          },
          "editor"
        )

      diff = CapAlert.diff_versions(v1, v2)
      region = Enum.find(diff.regions, &(&1.key == "440800,440900"))
      assert region.status == :changed
      headline = Enum.find(region.changes, &(&1.field == :headline))
      assert headline.changed
      assert headline.old =~ "暴雨红色预警"
      assert headline.new == "变更后标题"
    end
  end

  describe "CAP XML export/import through the context" do
    test "export then import round-trips the structured fields and infos" do
      {_alert, version} = create_alert!()
      xml = CapAlert.export_cap(version)
      assert is_binary(xml)
      assert xml =~ "<info>"

      assert {:ok, %{alert: alert, version: imported}} =
               CapAlert.import_cap(xml, "importer")

      assert alert.identifier == @identifier
      assert length(imported.infos) == 1
      assert imported.status == :actual
      info = hd(imported.infos)
      assert info.event == "暴雨"
      assert info.severity == :severe
      assert Enum.map(info.geocodes, & &1.value) |> Enum.sort() == ["440800", "440900"]
    end

    test "multi-info round-trip preserves info-to-area correspondence" do
      {:ok, %{version: version}} =
        CapAlert.create_alert(
          multi_info_attrs("CN-ROUNDTRIP-001"),
          "t"
        )

      xml = CapAlert.export_cap(version)
      assert {:ok, %{version: imported}} = CapAlert.import_cap(xml, "importer")

      assert length(imported.infos) == 2

      first = Enum.at(imported.infos, 0)
      second = Enum.at(imported.infos, 1)

      assert Enum.map(first.geocodes, & &1.value) == ["440800"]
      assert first.severity == :severe
      assert Enum.map(second.geocodes, & &1.value) == ["440900"]
      assert second.severity == :extreme
    end

    test "import rejects external entity documents" do
      xml =
        ~s(<?xml version="1.0"?><!DOCTYPE foo [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>) <>
          ~s(<alert xmlns="urn:oasis:names:tc:emergency:cap:1.2"><identifier>x</identifier></alert>)

      assert {:error, :doctype_or_entity_forbidden} = CapAlert.import_cap(xml, "importer")
    end
  end

  defp infos_param(infos) do
    infos
    |> Enum.with_index()
    |> Map.new(fn {info, idx} ->
      {Integer.to_string(idx),
       %{
         "event" => info.event,
         "headline" => info.headline,
         "severity" => info.severity && Atom.to_string(info.severity),
         "geocodes" =>
           info.geocodes
           |> Enum.with_index()
           |> Map.new(fn {gc, i} ->
             {Integer.to_string(i), %{"value_name" => gc.value_name, "value" => gc.value}}
           end)
       }}
    end)
  end

  defp multi_info_attrs(id) do
    %{
      "identifier" => id,
      "sender" => "s@example.com",
      "sent" => ~U[2026-07-29 08:00:00Z],
      "status" => "actual",
      "msg_type" => "alert",
      "scope" => "public",
      "infos" => %{
        "0" => %{
          "event" => "暴雨",
          "severity" => "severe",
          "geocodes" => %{"0" => %{"value_name" => "Same", "value" => "440800"}}
        },
        "1" => %{
          "event" => "暴雨",
          "severity" => "extreme",
          "geocodes" => %{"0" => %{"value_name" => "Same", "value" => "440900"}}
        }
      }
    }
  end

  describe "external import with concurrent stale draft" do
    @ext_identifier "CN-20260729-GD-RAIN-EXT-02"

    @ext_xml ~s"""
    <?xml version="1.0" encoding="UTF-8"?>
    <alert xmlns="urn:oasis:names:tc:emergency:cap:1.2">
      <identifier>CN-20260729-GD-RAIN-EXT-02</identifier>
      <sender>external-feed@gd.example</sender>
      <sent>2026-07-29T09:30:00+00:00</sent>
      <status>Actual</status>
      <msgType>Alert</msgType>
      <scope>Public</scope>
      <info>
        <language>zh-CN</language>
        <event>暴雨 &amp; 强对流</event>
        <urgency>Immediate</urgency>
        <severity>Severe</severity>
        <certainty>Likely</certainty>
        <headline>暴雨“红色”预警 &lt;升级&gt;</headline>
        <description>湛江降雨 &amp; 雷暴 &lt;持续&gt;</description>
        <ext:note xmlns:ext="urn:example:cap-ext" priority="高">外部备注 &amp; 详情</ext:note>
        <area>
          <areaDesc>湛江市</areaDesc>
          <geocode><valueName>Same</valueName><value>440800</value></geocode>
        </area>
      </info>
      <info>
        <language>zh-CN</language>
        <event>暴雨 &amp; 强对流</event>
        <urgency>Immediate</urgency>
        <severity>Extreme</severity>
        <certainty>Observed</certainty>
        <headline>暴雨“红色”预警 &lt;特别紧急&gt;</headline>
        <description>茂名降雨 &amp; 冰雹 &lt;加剧&gt;</description>
        <ext:note xmlns:ext="urn:example:cap-ext" priority="最高">外部备注 &amp; 详情二</ext:note>
        <area>
          <areaDesc>茂名市</areaDesc>
          <geocode><valueName>Same</valueName><value>440900</value></geocode>
        </area>
      </info>
    </alert>
    """

    setup do
      # Publish round 1
      {_alert, v1} = create_alert!()
      publish_chain!(v1)

      # Create C1 (round 2) draft, capture the stale draft struct before it moves
      assert {:ok, %{version: c1_draft}} =
               CapAlert.create_correction_alert(
                 %{"source_identifier" => @identifier},
                 "editor"
               )

      # Drive C1 through submit -> approve -> publish using fresh structs
      {:ok, submitted} = CapAlert.submit_for_review(c1_draft, "editor")
      {:ok, approved} = CapAlert.review(submitted, :approve, "ok", "reviewer")
      {:ok, published_c1} = CapAlert.publish(approved, "publisher")

      %{c1_draft: c1_draft, c1_id: "#{@identifier}-C1", published_c1: published_c1}
    end

    test "import creates an in_review version and round-trips special chars and extensions", %{
      c1_id: c1_id
    } do
      assert {:ok, %{alert: ext_alert, version: imported}} =
               CapAlert.import_cap(@ext_xml, "importer")

      assert ext_alert.identifier == @ext_identifier
      assert imported.workflow_state == :in_review
      assert length(imported.infos) == 2

      [info_440800, info_440900] = imported.infos
      assert hd(info_440800.geocodes).value == "440800"
      assert info_440800.severity == :severe
      assert hd(info_440900.geocodes).value == "440900"
      assert info_440900.severity == :extreme

      # Special characters are decoded
      assert info_440800.headline == ~s(暴雨“红色”预警 <升级>)
      assert info_440800.description =~ "降雨 & 雷暴 <持续>"
      assert info_440900.headline == ~s(暴雨“红色”预警 <特别紧急>)

      # Per-info unknown extension nodes are preserved
      assert length(info_440800.extensions) == 1
      assert length(info_440900.extensions) == 1

      # Round-trip through export and re-parse
      xml = CapAlert.export_cap(imported)
      assert {:ok, %{version: reimported}} = CapAlert.import_cap(xml, "roundtrip")

      # Re-importing an existing alert creates another in_review version
      assert reimported.workflow_state == :in_review
      assert reimported.version_number == 2
      assert length(reimported.infos) == 2

      [ri_1, ri_2] = reimported.infos
      assert ri_1.severity == :severe
      assert ri_2.severity == :extreme
      assert ri_1.headline == ~s(暴雨“红色”预警 <升级>)
      assert length(ri_1.extensions) == 1
      assert length(ri_2.extensions) == 1

      ext = hd(ri_2.extensions)
      assert ext["name"] == "ext:note"
      assert ext["attrs"]["priority"] == "最高"

      # C1 (round 2) region severities are untouched by the import
      c1 = CapAlert.get_alert!(c1_id)
      c1_version = CapAlert.get_version!(c1.latest_version_id)
      by_region = Map.new(c1_version.infos, fn i -> {hd(i.geocodes).value, i} end)
      assert by_region["440800"].severity == :severe
      assert by_region["440900"].severity == :extreme
    end

    test "submitting a stale pre-publish C1 draft returns not_latest_version", %{
      c1_draft: stale_draft,
      c1_id: c1_id,
      published_c1: published_c1
    } do
      # The stale struct still thinks it is a draft; the live row is already published
      assert stale_draft.workflow_state == :draft
      assert published_c1.workflow_state == :published

      assert {:error, :not_latest_version} =
               CapAlert.submit_for_review(stale_draft, "late-browser")

      # No mutation: C1 remains published with its round-2 region severities
      reloaded = CapAlert.get_version!(published_c1.id)
      assert reloaded.workflow_state == :published

      by_region = Map.new(reloaded.infos, fn i -> {hd(i.geocodes).value, i} end)
      assert by_region["440800"].severity == :severe
      assert by_region["440900"].severity == :extreme

      # No extra versions or outbox rows created for C1 by the rejected submit
      assert length(CapAlert.list_versions(c1_id)) == 1
      assert CapAlert.list_outbox(c1_id) |> length() == 1
    end
  end
end
