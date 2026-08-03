defmodule CapAlertWorkbench.Cap.VersionDiff do
  @moduledoc """
  Produces a field-by-field difference between two CAP message payloads.
  For multi-info messages the diff is reported per area code so that a
  correction that upgrades one region to `Extreme` while leaving another at
  `Severe` is shown clearly.
  """

  alias CapAlertWorkbench.Cap.Info

  @scalar_fields ~w(
    identifier sender sent_at status msg_type scope language urgency severity
    certainty event headline description instruction note references
  )

  @type field_change :: %{
          field: String.t(),
          area: String.t() | nil,
          before: term(),
          after_value: term(),
          change: :added | :removed | :modified | :unchanged
        }

  @spec diff(map(), map()) :: [field_change()]
  def diff(before_payload, after_payload)
      when is_map(before_payload) and is_map(after_payload) do
    before_infos = before_payload["infos"] || []
    after_infos = after_payload["infos"] || []

    scalar_changes =
      Enum.map(@scalar_fields, fn field ->
        b = before_payload[field]
        a = after_payload[field]
        classify(field, nil, b, a)
      end)

    area_changes = diff_infos_by_area(before_infos, after_infos)

    scalar_changes ++ area_changes
  end

  defp diff_infos_by_area(before_infos, after_infos) do
    before_by_area = index_infos_by_area(before_infos)
    after_by_area = index_infos_by_area(after_infos)

    all_areas =
      (Map.keys(before_by_area) ++ Map.keys(after_by_area))
      |> Enum.uniq()

    per_area_fields = ~w(severity urgency certainty headline description instruction event)

    Enum.flat_map(all_areas, fn area ->
      b_info = Map.get(before_by_area, area)
      a_info = Map.get(after_by_area, area)

      Enum.map(per_area_fields, fn field ->
        b = b_info && b_info[field]
        a = a_info && a_info[field]
        classify(field, area, b, a)
      end)
    end)
  end

  defp index_infos_by_area(infos) do
    Enum.reduce(infos, %{}, fn info, acc ->
      info
      |> normalize_info()
      |> Map.get("areas", [])
      |> Enum.reduce(acc, fn area, inner ->
        code = area["code"] || area.code
        Map.put(inner, code, normalize_info(info))
      end)
    end)
  end

  defp normalize_info(%Info{} = info) do
    %{
      "severity" => info.severity && Atom.to_string(info.severity),
      "urgency" => info.urgency && Atom.to_string(info.urgency),
      "certainty" => info.certainty && Atom.to_string(info.certainty),
      "headline" => info.headline,
      "description" => info.description,
      "instruction" => info.instruction,
      "event" => info.event,
      "areas" =>
        Enum.map(info.areas, fn area ->
          %{"code" => area.code, "description" => area.description}
        end)
    }
  end

  defp normalize_info(info) when is_map(info), do: info
  defp normalize_info(_), do: %{}

  defp classify(field, area, nil, value) when value not in [nil, "", []] do
    %{field: field, area: area, before: nil, after_value: value, change: :added}
  end

  defp classify(field, area, value, nil) when value not in [nil, "", []] do
    %{field: field, area: area, before: value, after_value: nil, change: :removed}
  end

  defp classify(field, area, same, same),
    do: %{field: field, area: area, before: same, after_value: same, change: :unchanged}

  defp classify(field, area, b, a) do
    %{field: field, area: area, before: b, after_value: a, change: :modified}
  end

  def changed_fields(diff) do
    Enum.filter(diff, &(&1.change != :unchanged))
  end
end
