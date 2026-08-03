defmodule CapAlertWorkbench.Cap.Document do
  @moduledoc """
  CAP 预警文档的结构化表示（领域层，纯数据结构）。

  一条文档由 alert 级字段（identifier/sender/sent/status/msgType/scope/references）
  与一至多个 `Info` 段组成。多 info 段用于表达分地区预警（如 440800 维持
  Severe、440900 升级 Extreme）。

  未识别的扩展元素以 `Element` 树原样保留在 alert 级 `extensions` 与各 info
  段的 `extensions` 中，序列化时按原样输出，保证导入导出 round-trip。

  `sent` 保存 ISO 8601 原文（导入时校验合法性，不做时区归一化），保证
  round-trip 字节级稳定。
  """

  alias CapAlertWorkbench.Cap.Enums
  alias CapAlertWorkbench.Cap.Info
  alias CapAlertWorkbench.Cap.Xml.Element

  @cap_namespace "urn:oasis:names:tc:emergency:cap:1.2"

  defstruct identifier: nil,
            sender: nil,
            sent: nil,
            status: :actual,
            msg_type: :alert,
            scope: :public,
            references: [],
            infos: [],
            extensions: []

  @type cap_reference :: %{sender: String.t(), identifier: String.t(), sent: String.t()}

  @type t :: %__MODULE__{
          identifier: String.t() | nil,
          sender: String.t() | nil,
          sent: String.t() | nil,
          status: atom(),
          msg_type: atom(),
          scope: atom(),
          references: [cap_reference()],
          infos: [Info.t()],
          extensions: [Element.t()]
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
    |> require_datetime(:sent, doc.sent)
    |> validate_infos(doc.infos)
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

  defp validate_infos(errors, []), do: [{:infos, "至少需要一个 info 段"} | errors]

  defp validate_infos(errors, infos) do
    infos
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {info, index}, acc ->
      acc
      |> require_info_present(index, :event, info.event)
      |> require_datetime({:info, index, :effective}, info.effective)
      |> require_datetime({:info, index, :expires}, info.expires)
      |> validate_geocodes(index, info.areas)
    end)
  end

  defp require_info_present(errors, index, field, value) do
    if is_binary(value) and String.trim(value) != "" do
      errors
    else
      [{{:info, index, field}, "info 段 #{index + 1} 的 #{field} 不能为空"} | errors]
    end
  end

  defp validate_geocodes(errors, index, areas) when is_list(areas) do
    Enum.reduce(areas, errors, fn area, acc ->
      geocodes = Map.get(area, :geocodes) || Map.get(area, "geocodes") || []

      if Enum.all?(geocodes, fn gc ->
           value = Map.get(gc, :value) || Map.get(gc, "value")
           is_binary(value) and String.trim(value) != ""
         end) do
        acc
      else
        [{{:info, index, :areas}, "info 段 #{index + 1} 的 geocode 编码不能为空"} | acc]
      end
    end)
  end

  # ------------------------------------------------------------------
  # Document -> Element 树（序列化由 Builder 完成，不拼接字符串）
  # ------------------------------------------------------------------

  @doc "把文档转换为 `alert` 根元素树。"
  @spec to_element(t()) :: Element.t()
  def to_element(%__MODULE__{} = doc) do
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
      |> Kernel.++(Enum.map(doc.infos, &info_to_element/1))
      |> Kernel.++(doc.extensions)

    Element.new("alert", [{"xmlns", @cap_namespace}], alert_children)
  end

  defp info_to_element(%Info{} = info) do
    children =
      [
        text_element("language", info.language),
        text_element("category", Enums.to_cap(:category, info.category)),
        text_element("event", info.event),
        text_element("urgency", Enums.to_cap(:urgency, info.urgency)),
        text_element("severity", Enums.to_cap(:severity, info.severity)),
        text_element("certainty", Enums.to_cap(:certainty, info.certainty))
      ]
      |> maybe_append("effective", info.effective)
      |> maybe_append("expires", info.expires)
      |> maybe_append("headline", info.headline)
      |> maybe_append("description", info.description)
      |> maybe_append("instruction", info.instruction)
      |> Kernel.++(Enum.map(info.areas, &area_element/1))
      |> Kernel.++(info.extensions)

    Element.new("info", [], children)
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
  未识别的 alert/info 级子元素保留为扩展。支持多个 info 段。
  """
  @spec from_element(Element.t()) :: {:ok, t()} | {:error, term()}
  def from_element(%Element{} = root) do
    if Element.local_name(root.name) == "alert" do
      with {:ok, status} <- enum_field(root, "status", :status),
           {:ok, msg_type} <- enum_field(root, "msgType", :msg_type),
           {:ok, scope} <- enum_field(root, "scope", :scope),
           {:ok, references} <- parse_references(Element.find_child(root, "references")),
           {:ok, infos} <- parse_infos(Element.find_children(root, "info")) do
        {:ok,
         %__MODULE__{
           identifier: child_text(root, "identifier"),
           sender: child_text(root, "sender"),
           sent: child_text(root, "sent"),
           status: status,
           msg_type: msg_type,
           scope: scope,
           references: references,
           infos: infos,
           extensions: extensions_of(root, @alert_known)
         }}
      end
    else
      {:error, {:unexpected_root, root.name}}
    end
  end

  defp parse_infos([]), do: {:error, {:missing_element, "info"}}

  defp parse_infos(info_elements) do
    Enum.reduce_while(info_elements, {:ok, []}, fn el, {:ok, acc} ->
      case parse_info(el) do
        {:ok, info} -> {:cont, {:ok, [info | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, infos} -> {:ok, Enum.reverse(infos)}
      error -> error
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

  defp parse_info(%Element{} = info_el) do
    with {:ok, urgency} <- enum_field(info_el, "urgency", :urgency),
         {:ok, severity} <- enum_field(info_el, "severity", :severity),
         {:ok, certainty} <- enum_field(info_el, "certainty", :certainty),
         {:ok, category} <- enum_field(info_el, "category", :category) do
      areas =
        info_el
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
       %Info{
         language: child_text(info_el, "language") || "zh-CN",
         category: category,
         event: child_text(info_el, "event"),
         urgency: urgency,
         severity: severity,
         certainty: certainty,
         effective: child_text(info_el, "effective"),
         expires: child_text(info_el, "expires"),
         headline: child_text(info_el, "headline"),
         description: child_text(info_el, "description"),
         instruction: child_text(info_el, "instruction"),
         areas: areas,
         extensions: extensions_of(info_el, @info_known)
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

  @alert_enum_fields [:status, :msg_type, :scope]

  @doc "文档 -> jsonb 可存储的纯 map。枚举显式映射为 CAP 字符串。"
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = doc) do
    enums =
      Map.new(@alert_enum_fields, fn f ->
        {Atom.to_string(f), Enums.to_cap(f, Map.get(doc, f))}
      end)

    %{
      "identifier" => doc.identifier,
      "sender" => doc.sender,
      "sent" => doc.sent,
      "references" =>
        Enum.map(doc.references, fn ref ->
          %{"sender" => ref.sender, "identifier" => ref.identifier, "sent" => ref.sent}
        end),
      "infos" => Enum.map(doc.infos, &Info.to_map/1),
      "extensions" => Enum.map(doc.extensions, &Element.to_map/1)
    }
    |> Map.merge(enums)
  end

  @doc "jsonb map -> 文档。枚举严格映射，未知值返回错误。"
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(%{} = map) do
    with {:ok, enums} <- parse_alert_enums(map),
         {:ok, infos} <- parse_info_maps(map["infos"] || []) do
      {:ok,
       struct!(
         __MODULE__,
         Map.merge(
           %{
             identifier: map["identifier"],
             sender: map["sender"],
             sent: map["sent"],
             references:
               Enum.map(map["references"] || [], fn ref ->
                 %{sender: ref["sender"], identifier: ref["identifier"], sent: ref["sent"]}
               end),
             infos: infos,
             extensions: Enum.map(map["extensions"] || [], &Element.from_map/1)
           },
           enums
         )
       )}
    end
  end

  defp parse_alert_enums(map) do
    Enum.reduce_while(@alert_enum_fields, {:ok, %{}}, fn field, {:ok, acc} ->
      case Enums.from_cap(field, Map.fetch!(map, Atom.to_string(field))) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp parse_info_maps(info_maps) do
    Enum.reduce_while(info_maps, {:ok, []}, fn info_map, {:ok, acc} ->
      case Info.from_map(info_map) do
        {:ok, info} -> {:cont, {:ok, [info | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, infos} -> {:ok, Enum.reverse(infos)}
      error -> error
    end
  end
end
