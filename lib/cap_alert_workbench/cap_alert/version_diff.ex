defmodule CapAlertWorkbench.CapAlert.VersionDiff do
  @moduledoc """
  Computes a field-level diff between two alert versions for review display.
  """

  @diff_fields [
    {:sender, "发送方"},
    {:sent, "发送时间"},
    {:status, "CAP 状态"},
    {:msg_type, "消息类型"},
    {:scope, "范围"},
    {:language, "语言"},
    {:event, "事件"},
    {:headline, "标题"},
    {:description, "描述"},
    {:instruction, "处置建议"},
    {:urgency, "紧急度"},
    {:severity, "严重度"},
    {:certainty, "确定性"},
    {:area_desc, "区域描述"},
    {:geocodes, "区域编码"},
    {:references, "引用"}
  ]

  @type field_change :: %{
          field: atom(),
          label: String.t(),
          old: term(),
          new: term(),
          changed: boolean()
        }

  @doc """
  Compare two version structs (or maps). Returns a list of field changes.
  """
  @spec diff(map(), map()) :: [field_change()]
  def diff(old_version, new_version) do
    Enum.map(@diff_fields, fn {field, label} ->
      old_val = normalize(field, Map.get(old_version, field))
      new_val = normalize(field, Map.get(new_version, field))

      %{
        field: field,
        label: label,
        old: old_val,
        new: new_val,
        changed: old_val != new_val
      }
    end)
  end

  defp normalize(:sent, %DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp normalize(:sent, nil), do: nil
  defp normalize(:sent, other), do: to_string(other)

  defp normalize(:geocodes, list) when is_list(list) do
    list
    |> Enum.map(fn gc ->
      name = val(gc, :value_name) || val(gc, "value_name")
      value = val(gc, :value) || val(gc, "value")
      "#{name}:#{value}"
    end)
    |> Enum.sort()
    |> Enum.join(", ")
  end

  defp normalize(_field, atom) when is_atom(atom) and not is_nil(atom), do: Atom.to_string(atom)
  defp normalize(_field, nil), do: nil
  defp normalize(_field, other), do: to_string(other)

  defp val(map, key) when is_map(map), do: Map.get(map, key)
end
