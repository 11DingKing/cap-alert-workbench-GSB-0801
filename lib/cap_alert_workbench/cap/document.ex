defmodule CapAlertWorkbench.Cap.Document do
  @moduledoc """
  CAP 预警文档的结构化表示（领域层，纯数据结构）。

  字段使用受限 atom 枚举（见 `CapAlertWorkbench.Cap.Enums`）。
  未识别的扩展元素以 `Element` 树原样保留在 `alert_extensions` /
  `info_extensions` 中，序列化时按原样输出，保证导入导出 round-trip。

  `sent`、`effective`、`expires` 保存 ISO 8601 原文（导入时校验合法性，
  不做时区归一化），以保证 round-trip 字节级稳定。
  """

  alias CapAlertWorkbench.Cap.Enums
  alias CapAlertWorkbench.Cap.Xml.Element

  @cap_namespace "urn:oasis:names:tc:emergency:cap:1.2"

  defstruct identifier: nil,
            sender: nil,
            sent: nil,
            status: :actual,
            msg_type: :alert,
            scope: :public,
            references: [],
            language: "zh-CN",
            category: :met,
            event: nil,
            urgency: :immediate,
            severity: :severe,
            certainty: :likely,
            headline: nil,
            description: nil,
            instruction: nil,
            effective: nil,
            expires: nil,
            areas: [],
            alert_extensions: [],
            info_extensions: []

  @type cap_reference :: %{sender: String.t(), identifier: String.t(), sent: String.t()}
  @type geocode :: %{value_name: String.t(), value: String.t()}
  @type area :: %{area_desc: String.t() | nil, geocodes: [geocode()]}

  @type t :: %__MODULE__{
          identifier: String.t() | nil,
          sender: String.t() | nil,
          sent: String.t() | nil,
          status: atom(),
          msg_type: atom(),
          scope: atom(),
          references: [cap_reference()],
          language: String.t(),
          category: atom(),
          event: String.t() | nil,
          urgency: atom(),
          severity: atom(),
          certainty: atom(),
          headline: String.t() | nil,
          description: String.t() | nil,
          instruction: String.t() | nil,
          effective: String.t() | nil,
          expires: String.t() | nil,
          areas: [area()],
          alert_extensions: [Element.t()],
          info_extensions: [Element.t()]
        }

  def cap_namespace, do: @cap_namespace

  # ------------------------------------------------------------------
  # 校验
  # ------------------------------------------------------------------

  @doc "校验必填字段与枚举合法性，返回 :ok 或 {:error, [reason]}。"
  @spec validate(t()) :: :ok | {:error, [{atom(), String.t()}]}
  def validate(%__MODULE__{} = doc) do
    []
    |> require_present(:identifier, doc.identifier)
    |> require_present(:sender, doc.sender)
    |> require_present(:sent, doc.sent)
    |> require_present(:event, doc.event)
    |> require_datetime(:sent, doc.sent)
    |> require_datetime(:effective, doc.effective)
    |> require_datetime(:expires, doc.expires)
    |> validate_areas(doc.areas)
    |> case do
      [] -> :ok
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  defp require_present(errors, field, value) do
    if is_binary(value) and String.trim(value) != "" do
      errors
    else
      [{field, "不能为空"} | errors]
    end
  end

  defp require_datetime(errors, _field, nil), do: errors

  defp require_datetime(errors, field, value) do
    case DateTime.from_iso8601(value) do
      {:ok, _dt, _offset} -> errors
      {:error, _} -> [{field, "必须是合法的 ISO 8601 日期时间: #{value}"} | errors]
    end
  end

  defp validate_areas(errors, areas) when is_list(areas) do
    Enum.reduce(areas, errors, fn area, acc ->
      geocodes = Map.get(area, :geocodes) || Map.get(area, "geocodes") || []

      if Enum.all?(geocodes, fn gc ->
           value = Map.get(gc, :value) || Map.get(gc, "value")
           is_binary(value) and String.trim(value) != ""
         end) do
        acc
      else
        [{:areas, "geocode 编码不能为空"} | acc]
      end
    end)
  end

  # ------------------------------------------------------------------
  # Document -> Element 树（序列化由 Builder 完成，不拼接字符串）
  # ------------------------------------------------------------------

  @doc "把文档转换为 `alert` 根元素树。"
  @spec to_element(t()) :: Element.t()
  def to_element(%__MODULE__{} = doc) do
    info_children =
      [
        text_element("language", doc.language),
        text_element("category", Enums.to_cap(:category, doc.category)),
        text_element("event", doc.event),
        text_element("urgency", Enums.to_cap(:urgency, doc.urgency)),
        text_element("severity", Enums.to_cap(:severity, doc.severity)),
        text_element("certainty", Enums.to_cap(:certainty, doc.certainty))
      ]
      |> maybe_append("effective", doc.effective)
      |> maybe_append("expires", doc.expires)
      |> maybe_append("headline", doc.headline)
      |> maybe_append("description", doc.description)
      |> maybe_append("instruction", doc.instruction)
      |> Kernel.++(Enum.map(doc.areas, &area_element/1))
      |> Kernel.++(doc.info_extensions)

    alert_children =
      [
        text_element("identifier", doc.identifier),
        text_element("sender", doc.sender),
        text_element("sent", doc.sent),
        text_element("status", Enums.to_cap(:status, doc.status)),
        text_element("msgType", Enums.to_cap(:msg_type, doc.msg_type)),
        text_element("scope", Enums.to_cap(:scope, doc.scope))
      ]
      |> maybe_append_references(doc.references)
      |> Kernel.++([Element.new("info", [], info_children)])
      |> Kernel.++(doc.alert_extensions)

    Element.new("alert", [{"xmlns", @cap_namespace}], alert_children)
  end

  defp text_element(_name, nil), do: nil
  defp text_element(name, value), do: Element.new(name, [], [value])

  defp maybe_append(elements, _name, nil), do: elements
  defp maybe_append(elements, name, value), do: elements ++ [text_element(name, value)]

  defp maybe_append_references(elements, []), do: elements

  defp maybe_append_references(elements, references) do
    value =
      Enum.map_join(references, " ", fn ref ->
        Enum.join([ref.sender, ref.identifier, ref.sent], ",")
      end)

    elements ++ [Element.new("references", [], [value])]
  end

  defp area_element(area) do
    desc = Map.get(area, :area_desc) || Map.get(area, "area_desc")
    geocodes = Map.get(area, :geocodes) || Map.get(area, "geocodes") || []

    geocode_elements =
      Enum.map(geocodes, fn gc ->
        value_name = Map.get(gc, :value_name) || Map.get(gc, "value_name")
        value = Map.get(gc, :value) || Map.get(gc, "value")

        Element.new("geocode", [], [
          text_element("valueName", value_name),
          text_element("value", value)
        ])
      end)

    children =
      case desc do
        nil -> geocode_elements
        "" -> geocode_elements
        text -> [text_element("areaDesc", text) | geocode_elements]
      end

    Element.new("area", [], children)
  end

  # ------------------------------------------------------------------
  # Element 树 -> Document（解析；严格枚举映射，未知元素保留）
  # ------------------------------------------------------------------

  @alert_known ~w(identifier sender sent status msgType scope references info)
  @info_known ~w(language category event urgency severity certainty effective expires
                 headline description instruction area)

  @doc """
  从元素树解析文档。根元素本地名必须是 `alert`；枚举值严格映射；
  未识别的 alert/info 级子元素保留为扩展。
  """
  @spec from_element(Element.t()) :: {:ok, t()} | {:error, term()}
  def from_element(%Element{} = root) do
    if Element.local_name(root.name) == "alert" do
      with {:ok, status} <- enum_field(root, "status", :status),
           {:ok, msg_type} <- enum_field(root, "msgType", :msg_type),
           {:ok, scope} <- enum_field(root, "scope", :scope),
           {:ok, references} <- parse_references(Element.find_child(root, "references")),
           {:ok, info_fields} <- parse_info(Element.find_child(root, "info")) do
        doc = %__MODULE__{
          identifier: child_text(root, "identifier"),
          sender: child_text(root, "sender"),
          sent: child_text(root, "sent"),
          status: status,
          msg_type: msg_type,
          scope: scope,
          references: references,
          alert_extensions: extensions_of(root, @alert_known)
        }

        {:ok, Map.merge(doc, info_fields)}
      end
    else
      {:error, {:unexpected_root, root.name}}
    end
  end

  defp enum_field(parent, element_name, kind) do
    case Element.find_child(parent, element_name) do
      nil -> {:error, {:missing_element, element_name}}
      el -> Enums.from_cap(kind, Element.text(el))
    end
  end

  defp parse_references(nil), do: {:ok, []}

  defp parse_references(%Element{} = el) do
    el
    |> Element.text()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reduce_while({:ok, []}, fn group, {:ok, acc} ->
      case String.split(group, ",") do
        [sender, identifier, sent] ->
          {:cont, {:ok, [%{sender: sender, identifier: identifier, sent: sent} | acc]}}

        _other ->
          {:halt, {:error, {:invalid_references, group}}}
      end
    end)
    |> case do
      {:ok, refs} -> {:ok, Enum.reverse(refs)}
      error -> error
    end
  end

  defp parse_info(nil), do: {:error, {:missing_element, "info"}}

  defp parse_info(%Element{} = info) do
    with {:ok, urgency} <- enum_field(info, "urgency", :urgency),
         {:ok, severity} <- enum_field(info, "severity", :severity),
         {:ok, certainty} <- enum_field(info, "certainty", :certainty),
         {:ok, category} <- enum_field(info, "category", :category) do
      areas =
        info
        |> Element.find_children("area")
        |> Enum.map(fn area ->
          geocodes =
            area
            |> Element.find_children("geocode")
            |> Enum.map(fn gc ->
              %{value_name: child_text(gc, "valueName"), value: child_text(gc, "value")}
            end)

          %{area_desc: child_text(area, "areaDesc"), geocodes: geocodes}
        end)

      {:ok,
       %{
         language: child_text(info, "language") || "zh-CN",
         category: category,
         event: child_text(info, "event"),
         urgency: urgency,
         severity: severity,
         certainty: certainty,
         effective: child_text(info, "effective"),
         expires: child_text(info, "expires"),
         headline: child_text(info, "headline"),
         description: child_text(info, "description"),
         instruction: child_text(info, "instruction"),
         areas: areas,
         info_extensions: extensions_of(info, @info_known)
       }}
    end
  end

  defp extensions_of(parent, known_locals) do
    parent.children
    |> Enum.filter(fn
      %Element{name: name} -> Element.local_name(name) not in known_locals
      _text -> false
    end)
  end

  defp child_text(parent, local) do
    case Element.find_child(parent, local) do
      nil ->
        nil

      el ->
        case Element.text(el) do
          "" -> nil
          text -> text
        end
    end
  end

  # ------------------------------------------------------------------
  # jsonb 存储映射（纯 map，不含 struct）
  # ------------------------------------------------------------------

  @scalar_fields [
    :identifier,
    :sender,
    :sent,
    :language,
    :event,
    :headline,
    :description,
    :instruction,
    :effective,
    :expires
  ]

  @enum_fields [:status, :msg_type, :scope, :category, :urgency, :severity, :certainty]

  @doc "文档 -> jsonb 可存储的纯 map。枚举显式映射为 CAP 字符串。"
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = doc) do
    scalars = Map.new(@scalar_fields, fn f -> {Atom.to_string(f), Map.get(doc, f)} end)

    enums =
      Map.new(@enum_fields, fn f -> {Atom.to_string(f), Enums.to_cap(f, Map.get(doc, f))} end)

    scalars
    |> Map.merge(enums)
    |> Map.put("references", Enum.map(doc.references, &stringify_keys/1))
    |> Map.put("areas", Enum.map(doc.areas, &area_to_map/1))
    |> Map.put("alert_extensions", Enum.map(doc.alert_extensions, &Element.to_map/1))
    |> Map.put("info_extensions", Enum.map(doc.info_extensions, &Element.to_map/1))
  end

  @doc "jsonb map -> 文档。枚举严格映射，未知值返回错误。"
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(%{} = map) do
    with {:ok, enums} <- parse_enum_map(map) do
      doc =
        struct!(
          __MODULE__,
          Map.merge(
            %{
              identifier: map["identifier"],
              sender: map["sender"],
              sent: map["sent"],
              language: map["language"] || "zh-CN",
              event: map["event"],
              headline: map["headline"],
              description: map["description"],
              instruction: map["instruction"],
              effective: map["effective"],
              expires: map["expires"],
              references:
                Enum.map(map["references"] || [], fn ref ->
                  %{sender: ref["sender"], identifier: ref["identifier"], sent: ref["sent"]}
                end),
              areas:
                Enum.map(map["areas"] || [], fn area ->
                  %{
                    area_desc: area["area_desc"],
                    geocodes:
                      Enum.map(area["geocodes"] || [], fn gc ->
                        %{value_name: gc["value_name"], value: gc["value"]}
                      end)
                  }
                end),
              alert_extensions: Enum.map(map["alert_extensions"] || [], &Element.from_map/1),
              info_extensions: Enum.map(map["info_extensions"] || [], &Element.from_map/1)
            },
            enums
          )
        )

      {:ok, doc}
    end
  end

  defp parse_enum_map(map) do
    Enum.reduce_while(@enum_fields, {:ok, %{}}, fn field, {:ok, acc} ->
      case Enums.from_cap(field, Map.fetch!(map, Atom.to_string(field))) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp area_to_map(area) do
    %{
      "area_desc" => Map.get(area, :area_desc) || Map.get(area, "area_desc"),
      "geocodes" =>
        Enum.map(Map.get(area, :geocodes) || Map.get(area, "geocodes") || [], fn gc ->
          %{
            "value_name" => Map.get(gc, :value_name) || Map.get(gc, "value_name"),
            "value" => Map.get(gc, :value) || Map.get(gc, "value")
          }
        end)
    }
  end
end
