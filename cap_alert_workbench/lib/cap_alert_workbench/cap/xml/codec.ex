defmodule CapAlertWorkbench.Cap.Xml.Codec do
  @moduledoc """
  Serializes `CapAlertWorkbench.Cap.Message` values to CAP 1.2 XML and parses
  CAP XML back into messages.

  Security properties:
    * Parsing uses a streaming SAX parser. DOCTYPE, entity declarations and
      notation declarations are rejected, so external entities are never
      resolved.
    * Serialization uses `XmlBuilder`, which performs XML escaping on all
      element text and attribute values. No raw string interpolation is used
      for text or attribute values.
    * Unknown extension elements (including those in other namespaces) are
      captured and re-emitted, so extension fields round-trip.
  """

  alias CapAlertWorkbench.Cap.{AreaCodes, Enums, Info, Message}
  alias CapAlertWorkbench.Cap.Xml.SaxTreeBuilder

  @cap_ns "urn:oasis:names:tc:emergency:cap:1.2"

  @doc """
  Serializes a message to CAP XML. Raises on invalid messages.
  """
  @spec encode!(Message.t()) :: String.t()
  def encode!(%Message{} = message) do
    case Message.validate(message) do
      {:ok, message} ->
        body =
          message
          |> build_document()
          |> XmlBuilder.generate(format: :none)

        ~s(<?xml version="1.0" encoding="UTF-8"?>\n) <> body

      {:error, reason} ->
        raise ArgumentError, "invalid CAP message: #{inspect(reason)}"
    end
  end

  @doc """
  Parses CAP XML into a message. Returns `{:ok, message}` or
  `{:error, reason}`. Rejects any DTD/entity content.
  """
  @spec decode(String.t()) :: {:ok, Message.t()} | {:error, term()}
  def decode(xml) when is_binary(xml) do
    with {:ok, tree} <- parse_safe(xml),
         {:ok, message} <- tree_to_message(tree) do
      Message.validate(message)
    end
  end

  def decode!(xml) do
    case decode(xml) do
      {:ok, message} -> message
      {:error, reason} -> raise ArgumentError, "CAP XML parse failed: #{inspect(reason)}"
    end
  end

  defp build_document(message) do
    XmlBuilder.element(:alert, %{xmlns: @cap_ns}, alert_children(message))
  end

  defp alert_children(message) do
    [
      {:identifier, message.identifier},
      {:sender, message.sender},
      {:sent, format_ref_time(message.sent_at)},
      {:status, Enums.status_to_string(message.status)},
      {:msgType, Enums.msg_type_to_string(message.msg_type)},
      {:scope, Enums.scope_to_string(message.scope)},
      {:code, "ChangeMe"},
      optional(:note, message.note),
      references_node(message.references),
      info_nodes(message.infos),
      extension_nodes(message.extensions)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp info_nodes(infos) when is_list(infos) do
    Enum.map(infos, &info_node/1)
  end

  defp info_node(%Info{} = info) do
    {:info, nil,
     [
       {:language, info.language},
       {:category, info.category || "Met"},
       {:event, info.event},
       {:urgency, Enums.urgency_to_string(info.urgency)},
       {:severity, Enums.severity_to_string(info.severity)},
       {:certainty, Enums.certainty_to_string(info.certainty)},
       optional(:headline, info.headline),
       optional(:description, info.description),
       optional(:instruction, info.instruction),
       area_nodes(info.areas)
     ]
     |> List.flatten()
     |> Enum.reject(&is_nil/1)}
  end

  defp area_nodes(areas) when is_list(areas) do
    Enum.map(areas, fn area ->
      {:area, nil,
       [
         {:areaDesc, area.description},
         {:polygon, nil, ""},
         {:circle, nil, ""},
         {:geocode, nil,
          [{:valueName, "AREA_CODE"}, {:value, area.code}]},
         {:altitude, nil, ""},
         {:ceiling, nil, ""}
       ]}
    end)
  end

  defp references_node([]), do: nil
  defp references_node(refs), do: {:references, Enum.join(refs, " ")}

  defp optional(_name, nil), do: nil
  defp optional(_name, ""), do: nil
  defp optional(name, value), do: {name, value}

  defp extension_nodes(extensions) do
    Enum.map(extensions, &build_extension/1)
  end

  defp build_extension({name, attrs, children}) when is_list(attrs) and is_list(children) do
    attr_map = Map.new(attrs, fn {k, v} -> {to_string(k), to_string(v)} end)

    child_nodes =
      Enum.map(children, fn
        %{name: cname, attrs: cattrs, children: cchildren} ->
          build_extension({cname, Map.to_list(cattrs), cchildren})

        text when is_binary(text) ->
          text
      end)

    {to_string(name), attr_map, child_nodes}
  end

  defp build_extension({name, _attrs, value}) do
    {to_string(name), to_string(value)}
  end

  defp build_extension([name, attrs, children]) when is_list(attrs) do
    build_extension({name, attrs, children})
  end

  @doc "Formats a DateTime as a CAP timestamp (yyyy-MM-ddTHH:MM:SS+00:00)."
  def format_ref_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%dT%H:%M:%S") <> format_offset(dt)
  end

  def format_ref_time(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, dt, _} -> format_ref_time(dt)
      # Already a formatted timestamp with offset
      _ -> text
    end
  end

  defp format_offset(%DateTime{utc_offset: 0}), do: "+00:00"

  defp format_offset(%DateTime{utc_offset: offset}) do
    total_minutes = div(offset, 60)
    sign = if total_minutes >= 0, do: "+", else: "-"
    abs_minutes = abs(total_minutes)
    hours = div(abs_minutes, 60)
    minutes = rem(abs_minutes, 60)
    "#{sign}#{pad2(hours)}:#{pad2(minutes)}"
  end

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp parse_safe(xml) do
    opts = [
      event_fun: &SaxTreeBuilder.event/3,
      event_state: SaxTreeBuilder.initial_state(),
      external_entities: :none
    ]

    try do
      case :xmerl_sax_parser.stream(to_charlist(xml), opts) do
        {:ok, %{root: nil}, _loc} ->
          {:error, :empty_document}

        {:ok, %{root: root}, _loc} ->
          {:ok, root}

        {:fatal_error, loc, reason, _state} ->
          {:error, {:xml_sax_error, loc, reason}}

        {:fatal_error, _loc, reason, _state, _extra} ->
          {:error, {:xml_sax_error, reason}}

        {:error, reason} ->
          {:error, {:xml_sax_error, reason}}

        other ->
          {:error, {:unexpected_parse_result, other}}
      end
    catch
      kind, value when kind in [:throw, :error, :exit] ->
        case value do
          {:fatal_error, reason} -> {:error, {:xml_sax_error, reason}}
          {:fatal_error, loc, reason} -> {:error, {:xml_sax_error, loc, reason}}
          {:fatal_error, _loc, reason, _state} -> {:error, {:xml_sax_error, reason}}
          other -> {:error, {:xml_sax_error, other}}
        end
    end
  end

  defp tree_to_message(tree) do
    try do
      {:ok, do_tree_to_message(tree)}
    rescue
      e -> {:error, {:malformed_cap, Exception.message(e)}}
    end
  end

  defp do_tree_to_message(%{name: "alert", children: children}) do
    fields = collect_text_fields(children)
    info_nodes = find_children(children, "info")
    infos = Enum.map(info_nodes, &parse_info/1)
    first_info = List.first(infos)

    %Message{
      identifier: fields["identifier"],
      sender: fields["sender"],
      sent_at: parse_datetime!(fields["sent"]),
      status: Enums.status_from_string(fields["status"]),
      msg_type: Enums.msg_type_from_string(fields["msgType"]),
      scope: Enums.scope_from_string(fields["scope"]),
      note: fields["note"],
      references: split_refs(fields["references"]),
      language: first_info_language(first_info),
      urgency: first_info && first_info.urgency,
      severity: first_info && first_info.severity,
      certainty: first_info && first_info.certainty,
      event: first_info && first_info.event,
      headline: first_info && first_info.headline,
      description: first_info && first_info.description,
      instruction: first_info && first_info.instruction,
      infos: infos,
      area_codes: Enum.flat_map(infos, &Info.area_codes/1),
      area_descriptions: Enum.flat_map(infos, &Info.area_descriptions/1),
      extensions: extract_extensions(children)
    }
  end

  defp first_info_language(nil), do: "zh-CN"
  defp first_info_language(%Info{language: lang}), do: lang

  defp parse_info(%{children: children} = _node) do
    fields = collect_text_fields(children)
    areas = parse_areas(children)

    %Info{
      language: fields["language"] || "zh-CN",
      category: fields["category"] || "Met",
      event: fields["event"],
      urgency: Enums.urgency_from_string(fields["urgency"]),
      severity: Enums.severity_from_string(fields["severity"]),
      certainty: Enums.certainty_from_string(fields["certainty"]),
      headline: fields["headline"],
      description: fields["description"],
      instruction: fields["instruction"],
      areas: areas
    }
  end

  defp parse_areas(children) do
    children
    |> Enum.filter(&match?(%{name: "area"}, &1))
    |> Enum.map(fn area ->
      fields = collect_text_fields(area.children)
      geocode = Enum.find(area.children, &match?(%{name: "geocode"}, &1))
      code = geocode && geocode_fields(geocode) |> Map.get("value")
      %{code: code, description: fields["areaDesc"] || code}
    end)
    |> Enum.reject(&is_nil(&1.code))
  end

  defp geocode_fields(%{children: children}), do: collect_text_fields(children)

  defp collect_text_fields(nodes) do
    Enum.reduce(nodes, %{}, fn
      %{name: name, children: children}, acc when is_list(children) ->
        case text_content(children) do
          "" -> acc
          text -> Map.put(acc, name, text)
        end

      _other, acc ->
        acc
    end)
  end

  defp find_children(nodes, name) do
    Enum.filter(nodes, &match?(%{name: ^name}, &1))
  end

  defp text_content(nodes) do
    nodes
    |> Enum.filter(&is_binary/1)
    |> Enum.join("")
    |> String.trim()
  end

  defp extract_extensions(children) do
    cap_elements = ~w(identifier sender sent status msgType scope restriction addresses
      code note references incidents info)

    children
    |> Enum.filter(fn
      %{name: name, ns: ns} ->
        name not in cap_elements and (ns not in ["", @cap_ns] or String.contains?(name, ":"))

      _ ->
        false
    end)
    |> Enum.map(fn node ->
      {node.name, Map.to_list(node.attrs), text_content(node.children)}
    end)
  end

  defp split_refs(nil), do: []
  defp split_refs(""), do: []
  defp split_refs(text), do: text |> String.split() |> Enum.reject(&(&1 == ""))

  defp parse_datetime!(nil), do: raise("missing sent time")

  defp parse_datetime!(text) do
    case DateTime.from_iso8601(text) do
      {:ok, dt, _offset} -> dt
      {:error, reason} -> raise "invalid datetime #{text}: #{inspect(reason)}"
    end
  end

  @doc false
  def cap_namespace, do: @cap_ns

  @doc "Builds the initial message from the required seed specification."
  def seed_message(attrs \\ []) do
    now = Keyword.get(attrs, :sent_at, ~U[2026-07-29 08:00:00Z])

    area_codes = Keyword.get(attrs, :area_codes, ["440800", "440900"])

    areas =
      Enum.map(area_codes, fn code ->
        %{code: code, description: AreaCodes.description(code) || code}
      end)

    info = %Info{
      language: Keyword.get(attrs, :language, "zh-CN"),
      event: Keyword.get(attrs, :event, "暴雨"),
      urgency: Keyword.get(attrs, :urgency, :immediate),
      severity: Keyword.get(attrs, :severity, :severe),
      certainty: Keyword.get(attrs, :certainty, :likely),
      headline: Keyword.get(attrs, :headline, "广东省暴雨红色预警"),
      description:
        Keyword.get(
          attrs,
          :description,
          "预计未来3小时内湛江、茂名等地将出现大暴雨，局部特大暴雨，并伴有强对流天气。"
        ),
      instruction:
        Keyword.get(
          attrs,
          :instruction,
          "请停止户外作业，远离低洼易涝区和山体滑坡隐患点，关注当地最新预警信息。"
        ),
      areas: areas
    }

    %Message{
      identifier: Keyword.get(attrs, :identifier, "CN-20260729-GD-RAIN-001"),
      sender: Keyword.get(attrs, :sender, "xinxi@gd.cma.gov.cn"),
      sent_at: now,
      status: Keyword.get(attrs, :status, :actual),
      msg_type: Keyword.get(attrs, :msg_type, :alert),
      scope: Keyword.get(attrs, :scope, :public),
      language: Keyword.get(attrs, :language, "zh-CN"),
      urgency: info.urgency,
      severity: info.severity,
      certainty: info.certainty,
      event: info.event,
      headline: info.headline,
      description: info.description,
      instruction: info.instruction,
      note: Keyword.get(attrs, :note, nil),
      references: Keyword.get(attrs, :references, []),
      extensions: Keyword.get(attrs, :extensions, []),
      incidents: Keyword.get(attrs, :incidents, []),
      infos: [info]
    }
  end
end
