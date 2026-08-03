defmodule CapAlertWorkbench.Cap.Xml.Parser do
  @moduledoc """
  基于 Saxy 的 SAX 解析器，把 XML 文本解析为 `Element` 树。

  安全性：Saxy 不解析 DTD、不展开也不抓取任何外部实体/外部 DTD
  （遇到未定义的实体引用直接报错），因此 XXE 载荷无法触发外部访问。
  命名空间前缀在元素名中保留（如 `cap:alert`），保证 round-trip 稳定。
  """

  alias CapAlertWorkbench.Cap.Xml.Element

  defmodule Handler do
    @moduledoc false
    @behaviour Saxy.Handler

    # state: %{stack: [Element.t(半成品)], roots: [Element.t]}
    # 半成品用 {name, attrs, children_rev} 表示，避免频繁重建 struct。

    @impl true
    def handle_event(:start_document, _prolog, state) do
      {:ok, state}
    end

    def handle_event(:start_element, {name, attrs}, %{stack: stack} = state) do
      attrs = Enum.map(attrs, fn {k, v} -> {to_string(k), to_string(v)} end)
      {:ok, %{state | stack: [{name, attrs, []} | stack]}}
    end

    def handle_event(:characters, chars, %{stack: [frame | rest]} = state) do
      {name, attrs, children_rev} = frame
      {:ok, %{state | stack: [{name, attrs, [chars | children_rev]} | rest]}}
    end

    def handle_event(:end_element, name, %{stack: [frame | rest]} = state) do
      {_name, attrs, children_rev} = frame
      element = %Element{name: name, attributes: attrs, children: Enum.reverse(children_rev)}

      case rest do
        [] ->
          {:ok, %{state | stack: [], roots: [element | state.roots]}}

        [{pname, pattrs, pchildren} | grand] ->
          {:ok, %{state | stack: [{pname, pattrs, [element | pchildren]} | grand]}}
      end
    end

    def handle_event(:end_document, _loc, state) do
      {:ok, state}
    end

    # CDATA 按字符数据处理
    def handle_event(:cdata, cdata, state), do: handle_event(:characters, cdata, state)
  end

  @doc """
  解析 XML 字符串为单个根 `Element`。

  返回 `{:ok, Element.t()}` 或 `{:error, reason}`。
  """
  @spec parse(String.t()) :: {:ok, Element.t()} | {:error, term()}
  def parse(xml) when is_binary(xml) do
    # 双保险：DTD/DOCTYPE 一律拒绝，外部实体与内部实体都无从声明。
    if String.contains?(xml, "<!DOCTYPE") do
      {:error, :doctype_forbidden}
    else
      do_parse(xml)
    end
  end

  defp do_parse(xml) do
    initial = %{stack: [], roots: []}

    case Saxy.parse_string(xml, Handler, initial) do
      {:ok, %{roots: [root]}} -> {:ok, strip_ws(root)}
      {:ok, %{roots: []}} -> {:error, :empty_document}
      {:ok, %{roots: _}} -> {:error, :multiple_roots}
      {:error, %Saxy.ParseError{} = error} -> {:error, {:malformed_xml, Exception.message(error)}}
      {:error, other} -> {:error, other}
    end
  end

  # 移除元素之间的纯空白文本节点（pretty-printed XML 的缩进），
  # 但保留元素内的实际文本内容。规则：若某元素含有子元素，则丢弃其
  # 纯空白文本节点；若只有文本，则保留。
  defp strip_ws(%Element{children: children} = el) do
    has_element_child? = Enum.any?(children, &match?(%Element{}, &1))

    children =
      if has_element_child? do
        children
        |> Enum.reject(fn
          text when is_binary(text) -> String.trim(text) == ""
          %Element{} -> false
        end)
        |> Enum.map(fn
          %Element{} = child -> strip_ws(child)
          text -> text
        end)
      else
        children
      end

    %Element{el | children: children}
  end
end
