defmodule CapAlertWorkbench.Cap.Enums do
  @moduledoc """
  CAP 1.2 枚举的显式映射。

  所有 CAP 枚举值在系统内部使用受限 atom 表示，与 CAP XML 字符串之间的
  转换必须通过本模块的 `to_cap/2` 与 `from_cap/3` 完成。两个方向都使用
  模式匹配的显式映射：未知值返回 `{:error, {:unknown_enum, kind, value}}`，
  绝不调用 `String.to_atom/1`，也不做自由字符串拼接。
  """

  @statuses [
    {:actual, "Actual"},
    {:exercise, "Exercise"},
    {:system, "System"},
    {:test, "Test"},
    {:draft, "Draft"}
  ]

  @msg_types [
    {:alert, "Alert"},
    {:update, "Update"},
    {:cancel, "Cancel"},
    {:ack, "Ack"},
    {:error, "Error"}
  ]

  @scopes [
    {:public, "Public"},
    {:restricted, "Restricted"},
    {:private, "Private"}
  ]

  @urgencies [
    {:immediate, "Immediate"},
    {:expected, "Expected"},
    {:future, "Future"},
    {:past, "Past"},
    {:unknown, "Unknown"}
  ]

  @severities [
    {:extreme, "Extreme"},
    {:severe, "Severe"},
    {:moderate, "Moderate"},
    {:minor, "Minor"},
    {:unknown, "Unknown"}
  ]

  @certainties [
    {:observed, "Observed"},
    {:likely, "Likely"},
    {:possible, "Possible"},
    {:unlikely, "Unlikely"},
    {:unknown, "Unknown"}
  ]

  @categories [
    {:geo, "Geo"},
    {:met, "Met"},
    {:safety, "Safety"},
    {:security, "Security"},
    {:rescue, "Rescue"},
    {:fire, "Fire"},
    {:health, "Health"},
    {:env, "Env"},
    {:transport, "Transport"},
    {:infra, "Infra"},
    {:cbrne, "CBRNE"},
    {:other, "Other"}
  ]

  @kinds %{
    status: @statuses,
    msg_type: @msg_types,
    scope: @scopes,
    urgency: @urgencies,
    severity: @severities,
    certainty: @certainties,
    category: @categories
  }

  @type kind :: :status | :msg_type | :scope | :urgency | :severity | :certainty | :category

  @doc "返回某类枚举的全部合法 atom 值，用于校验与下拉框渲染。"
  @spec values(kind()) :: [atom()]
  def values(kind) do
    case Map.fetch(@kinds, kind) do
      {:ok, pairs} -> Enum.map(pairs, &elem(&1, 0))
      :error -> raise ArgumentError, "unknown enum kind: #{inspect(kind)}"
    end
  end

  @doc "atom -> CAP 字符串，显式映射。"
  @spec to_cap(kind(), atom()) :: String.t()
  def to_cap(kind, value) when is_atom(value) do
    case Enum.find(Map.fetch!(@kinds, kind), fn {atom, _cap} -> atom == value end) do
      {^value, cap} -> cap
      nil -> raise ArgumentError, "invalid #{kind}: #{inspect(value)}"
    end
  end

  @doc "CAP 字符串 -> atom，显式映射；未知字符串返回错误元组。"
  @spec from_cap(kind(), String.t()) ::
          {:ok, atom()} | {:error, {:unknown_enum, kind(), String.t()}}
  def from_cap(kind, value) when is_binary(value) do
    case Enum.find(Map.fetch!(@kinds, kind), fn {_atom, cap} -> cap == value end) do
      {atom, ^value} -> {:ok, atom}
      nil -> {:error, {:unknown_enum, kind, value}}
    end
  end
end
