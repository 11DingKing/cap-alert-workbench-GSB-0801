defmodule CapAlertWorkbench.Cap.Xml.Element do
  @moduledoc """
  通用 XML 元素树节点。

  - `name`：限定名（含命名空间前缀，如 `"cap:alert"`）
  - `attributes`：`[{name, value}]` 有序列表，保证属性顺序 round-trip 稳定
  - `children`：子节点列表，元素为 `%Element{}`，文本为 `String.t()`

  未知扩展字段以此结构原样保留，序列化时按原顺序输出。
  """

  @enforce_keys [:name]
  defstruct name: nil, attributes: [], children: []

  @type t :: %__MODULE__{
          name: String.t(),
          attributes: [{String.t(), String.t()}],
          children: [t() | String.t()]
        }

  @doc "新建元素。attrs 为 keyword/map，children 为子节点列表。"
  def new(name, attrs \\ [], children \\ []) do
    %__MODULE__{name: name, attributes: normalize_attrs(attrs), children: children}
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    attrs |> Enum.sort_by(fn {k, _v} -> to_string(k) end) |> normalize_attrs()
  end

  defp normalize_attrs(attrs) when is_list(attrs) do
    Enum.map(attrs, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  @doc "取限定名的本地名（去掉命名空间前缀）。"
  @spec local_name(String.t()) :: String.t()
  def local_name(name) do
    case String.split(name, ":", parts: 2) do
      [_prefix, local] -> local
      [_] -> name
    end
  end

  @doc "提取元素的直接文本内容（忽略子元素）。"
  @spec text(t()) :: String.t()
  def text(%__MODULE__{children: children}) do
    children |> Enum.filter(&is_binary/1) |> IO.iodata_to_binary() |> String.trim()
  end

  @doc "按本地名查找直接子元素。"
  @spec find_child(t(), String.t()) :: t() | nil
  def find_child(%__MODULE__{children: children}, local) do
    Enum.find(children, fn
      %__MODULE__{name: name} -> local_name(name) == local
      _text -> false
    end)
  end

  @doc "按本地名查找全部直接子元素。"
  @spec find_children(t(), String.t()) :: [t()]
  def find_children(%__MODULE__{children: children}, local) do
    Enum.filter(children, fn
      %__MODULE__{name: name} -> local_name(name) == local
      _text -> false
    end)
  end

  @doc "转换为可 JSON 序列化的纯 map（存入 jsonb）。"
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = el) do
    %{
      "name" => el.name,
      "attributes" => Enum.map(el.attributes, fn {k, v} -> [k, v] end),
      "children" =>
        Enum.map(el.children, fn
          %__MODULE__{} = child -> to_map(child)
          text when is_binary(text) -> text
        end)
    }
  end

  @doc "从 jsonb 读出的纯 map 还原元素树。"
  @spec from_map(map()) :: t()
  def from_map(%{"name" => name, "attributes" => attrs, "children" => children}) do
    %__MODULE__{
      name: name,
      attributes: Enum.map(attrs, fn [k, v] -> {k, v} end),
      children:
        Enum.map(children, fn
          %{} = child -> from_map(child)
          text when is_binary(text) -> text
        end)
    }
  end
end
