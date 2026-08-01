defmodule CapAlertWorkbench.Cap.Xml do
  @moduledoc """
  CAP XML 序列化/解析门面（领域/服务层）。

  - `serialize/1`：`Document` -> CAP XML 文本（经 Element 树 + XmlBuilder，无字符串拼接）
  - `parse/1`：CAP XML 文本 -> `Document`（SAX 解析，不解析外部实体）
  """

  alias CapAlertWorkbench.Cap.Document
  alias CapAlertWorkbench.Cap.Xml.{Builder, Parser}

  @spec serialize(Document.t()) :: String.t()
  def serialize(%Document{} = doc) do
    doc |> Document.to_element() |> Builder.render_document()
  end

  @spec parse(String.t()) :: {:ok, Document.t()} | {:error, term()}
  def parse(xml) when is_binary(xml) do
    with {:ok, root} <- Parser.parse(xml),
         {:ok, doc} <- Document.from_element(root) do
      {:ok, doc}
    end
  end
end
