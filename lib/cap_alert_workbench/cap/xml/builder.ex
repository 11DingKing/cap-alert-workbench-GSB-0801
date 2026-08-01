defmodule CapAlertWorkbench.Cap.Xml.Builder do
  @moduledoc """
  把 `Element` 树序列化为 XML 文本。

  序列化全部经由 `XmlBuilder` 完成：标签/属性/文本的转义由专门的
  构建库处理，代码中不进行任何 XML 字符串拼接。
  """

  alias CapAlertWorkbench.Cap.Xml.Element

  @doc "生成带 XML 声明的完整文档字符串。"
  @spec render_document(Element.t()) :: String.t()
  def render_document(%Element{} = root) do
    XmlBuilder.document(root.name, root.attributes, render_children(root.children))
    |> XmlBuilder.generate(format: :none)
  end

  @doc "生成元素片段（无 XML 声明）。"
  @spec render_element(Element.t()) :: String.t()
  def render_element(%Element{} = el) do
    XmlBuilder.element(el.name, el.attributes, render_children(el.children))
    |> XmlBuilder.generate(format: :none)
  end

  defp render_children(children) do
    Enum.map(children, fn
      %Element{} = el -> {el.name, el.attributes, render_children(el.children)}
      text when is_binary(text) -> text
    end)
  end
end
