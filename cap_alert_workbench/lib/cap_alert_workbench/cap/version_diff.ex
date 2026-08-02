defmodule CapAlertWorkbench.Cap.VersionDiff do
  @moduledoc """
  Produces a stable field-by-field difference between two CAP message payloads.
  Used by the version-difference screen and the API.
  """

  @scalar_fields ~w(
    identifier sender sent_at status msg_type scope language urgency severity
    certainty event headline description instruction note
  )

  @list_fields ~w(area_codes area_descriptions references)

  @type change :: %{
          field: String.t(),
          before: term(),
          after_value: term(),
          change: :added | :removed | :modified | :unchanged
        }

  @spec diff(map(), map()) :: [change()]
  def diff(before_payload, after_payload) when is_map(before_payload) and is_map(after_payload) do
    scalar_changes =
      Enum.map(@scalar_fields, fn field ->
        b = Map.get(before_payload, field)
        a = Map.get(after_payload, field)
        classify(field, b, a)
      end)

    list_changes =
      Enum.map(@list_fields, fn field ->
        b = Map.get(before_payload, field) || []
        a = Map.get(after_payload, field) || []
        classify(field, b, a)
      end)

    scalar_changes ++ list_changes
  end

  defp classify(field, nil, value) when value not in [nil, "", []] do
    %{field: field, before: nil, after_value: value, change: :added}
  end

  defp classify(field, value, nil) when value not in [nil, "", []] do
    %{field: field, before: value, after_value: nil, change: :removed}
  end

  defp classify(field, same, same), do: %{field: field, before: same, after_value: same, change: :unchanged}

  defp classify(field, b, a) do
    %{field: field, before: b, after_value: a, change: :modified}
  end

  def changed_fields(diff) do
    Enum.filter(diff, &(&1.change != :unchanged))
  end
end
