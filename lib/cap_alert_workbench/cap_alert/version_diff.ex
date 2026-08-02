defmodule CapAlertWorkbench.CapAlert.VersionDiff do
  @moduledoc """
  Computes a per-region diff between two alert versions.

  Each `<info>` segment is indexed by the sorted set of its geocode values
  (e.g. `"440800"` or `"440800,440900"`). This makes it possible to show that
  a correction split a combined area into two regions: the old combined region
  appears as `:removed` while each new single-region info appears as `:added`.
  """

  @alert_fields [
    {:sender, "发送方"},
    {:sent, "发送时间"},
    {:status, "CAP 状态"},
    {:msg_type, "消息类型"},
    {:scope, "范围"},
    {:references, "引用"}
  ]

  @info_fields [
    {:event, "事件"},
    {:language, "语言"},
    {:urgency, "紧急度"},
    {:severity, "严重度"},
    {:certainty, "确定性"},
    {:headline, "标题"},
    {:description, "描述"},
    {:instruction, "处置建议"},
    {:area_desc, "区域描述"}
  ]

  @type field_change :: %{
          field: atom(),
          label: String.t(),
          old: term(),
          new: term(),
          changed: boolean()
        }

  @type region_diff :: %{
          key: String.t(),
          label: String.t(),
          status: :unchanged | :changed | :added | :removed,
          changes: [field_change()],
          old_info: map() | nil,
          new_info: map() | nil
        }

  @type diff_result :: %{
          alert_changes: [field_change()],
          regions: [region_diff()]
        }

  @spec diff(map(), map()) :: diff_result()
  def diff(old_version, new_version) do
    %{
      alert_changes: diff_alert_fields(old_version, new_version),
      regions: diff_infos(old_version, new_version)
    }
  end

  defp diff_alert_fields(old, new) do
    Enum.map(@alert_fields, fn {field, label} ->
      old_val = normalize(field, Map.get(old, field))
      new_val = normalize(field, Map.get(new, field))

      %{
        field: field,
        label: label,
        old: old_val,
        new: new_val,
        changed: old_val != new_val
      }
    end)
  end

  defp diff_infos(old, new) do
    old_map = infos_by_region(old)
    new_map = infos_by_region(new)

    keys =
      (Map.keys(old_map) ++ Map.keys(new_map))
      |> Enum.uniq()
      |> Enum.sort()

    Enum.map(keys, fn key ->
      old_info = Map.get(old_map, key)
      new_info = Map.get(new_map, key)

      build_region(key, old_info, new_info)
    end)
  end

  defp build_region(key, old_info, new_info) do
    cond do
      old_info != nil and new_info != nil ->
        changes = diff_info_fields(old_info, new_info)
        changed? = Enum.any?(changes, & &1.changed)

        %{
          key: key,
          label: region_label(old_info, new_info),
          status: if(changed?, do: :changed, else: :unchanged),
          changes: changes,
          old_info: info_summary(old_info),
          new_info: info_summary(new_info)
        }

      old_info != nil ->
        %{
          key: key,
          label: region_label(old_info, nil),
          status: :removed,
          changes: [],
          old_info: info_summary(old_info),
          new_info: nil
        }

      true ->
        %{
          key: key,
          label: region_label(nil, new_info),
          status: :added,
          changes: [],
          old_info: nil,
          new_info: info_summary(new_info)
        }
    end
  end

  defp diff_info_fields(old_info, new_info) do
    Enum.map(@info_fields, fn {field, label} ->
      old_val = normalize(field, Map.get(old_info, field))
      new_val = normalize(field, Map.get(new_info, field))

      %{
        field: field,
        label: label,
        old: old_val,
        new: new_val,
        changed: old_val != new_val
      }
    end)
  end

  defp infos_by_region(version) do
    infos = Map.get(version, :infos) || Map.get(version, "infos") || []

    infos
    |> Enum.map(fn info ->
      key = region_key(info)
      {key, info}
    end)
    |> Map.new()
  end

  defp region_key(info) do
    geocodes = Map.get(info, :geocodes) || Map.get(info, "geocodes") || []

    geocodes
    |> Enum.map(fn gc ->
      Map.get(gc, :value) || Map.get(gc, "value") || ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.sort()
    |> Enum.join(",")
  end

  defp region_label(old_info, new_info) do
    info = old_info || new_info
    geocodes = Map.get(info, :geocodes) || Map.get(info, "geocodes") || []
    area_desc = Map.get(info, :area_desc) || Map.get(info, "area_desc")

    codes =
      geocodes
      |> Enum.map(fn gc -> Map.get(gc, :value) || Map.get(gc, "value") end)
      |> Enum.join(", ")

    if area_desc not in [nil, ""] do
      "#{area_desc} (#{codes})"
    else
      codes
    end
  end

  defp info_summary(info) when is_map(info) do
    %{
      event: Map.get(info, :event) || Map.get(info, "event"),
      headline: Map.get(info, :headline) || Map.get(info, "headline"),
      severity: Map.get(info, :severity) || Map.get(info, "severity"),
      urgency: Map.get(info, :urgency) || Map.get(info, "urgency"),
      certainty: Map.get(info, :certainty) || Map.get(info, "certainty"),
      description: Map.get(info, :description) || Map.get(info, "description"),
      area_desc: Map.get(info, :area_desc) || Map.get(info, "area_desc")
    }
  end

  defp info_summary(nil), do: nil

  defp normalize(:sent, %DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp normalize(:sent, nil), do: nil
  defp normalize(:sent, other), do: to_string(other)

  defp normalize(_field, atom) when is_atom(atom) and not is_nil(atom), do: Atom.to_string(atom)
  defp normalize(_field, nil), do: nil
  defp normalize(_field, other), do: to_string(other)
end
