defmodule CapAlertWorkbench.CapAlert.CapXml do
  @moduledoc """
  CAP 1.2 XML parsing and serialization.

  * Parsing uses OTP's built-in `:xmerl`. External entities are never fetched:
    any document containing a `<!DOCTYPE>` or `<!ENTITY>` declaration is
    rejected outright, and the scanner is configured with `external_dtd: :none`.
  * Serialization uses `XmlBuilder`, which builds an XML tree (not string
    concatenation) and performs proper escaping of `&`, `<`, `>`, `"` and `'`.
  * Multiple `<info>` segments are supported and preserved in document order
    so that the info↔area correspondence is unchanged after a round-trip.
  * Unknown extension elements (including namespace-qualified ones) are
    preserved through an import/export round-trip.

  The internal element representation is a simple tuple tree:

      {name :: String.t(), attrs :: %{String.t() => String.t()}, children :: [element | String.t()]}
  """

  alias CapAlertWorkbench.CapAlert.Enums

  @cap_ns "urn:oasis:names:tc:emergency:cap:1.2"

  @type element ::
          {String.t(), %{optional(String.t()) => String.t()}, [element | String.t()]}

  @type info_fields :: %{
          optional(:language) => String.t() | nil,
          optional(:event) => String.t() | nil,
          optional(:urgency) => Enums.cap_urgency(),
          optional(:severity) => Enums.cap_severity(),
          optional(:certainty) => Enums.cap_certainty(),
          optional(:headline) => String.t() | nil,
          optional(:description) => String.t() | nil,
          optional(:instruction) => String.t() | nil,
          optional(:area_desc) => String.t() | nil,
          optional(:geocodes) => [%{value_name: String.t(), value: String.t()}],
          optional(:info_extensions) => [element()]
        }

  @type cap_fields :: %{
          optional(:identifier) => String.t(),
          optional(:sender) => String.t(),
          optional(:sent) => DateTime.t() | String.t(),
          optional(:status) => Enums.cap_status(),
          optional(:msg_type) => Enums.cap_msg_type(),
          optional(:scope) => Enums.cap_scope(),
          optional(:references) => String.t() | nil,
          optional(:infos) => [info_fields()],
          optional(:alert_extensions) => [element()]
        }

  @doc """
  Parse a CAP XML document into the simple element tree.
  Rejects DOCTYPE/ENTITY declarations to prevent XXE.
  """
  @spec parse(String.t()) :: {:ok, element()} | {:error, term()}
  def parse(xml) when is_binary(xml) do
    if unsafe_doctype?(xml) do
      {:error, :doctype_or_entity_forbidden}
    else
      do_parse(xml)
    end
  end

  defp unsafe_doctype?(xml) do
    stripped = xml |> String.replace(~r/<\?xml.*?\?>/s, "")
    Regex.match?(~r/<!DOCTYPE|<!ENTITY/i, stripped)
  end

  defp do_parse(xml) do
    bytes = :binary.bin_to_list(xml)

    case :xmerl_scan.string(bytes, [
           {:quiet, true},
           {:encoding, ~c"utf-8"}
         ]) do
      {doc, []} -> {:ok, normalize(doc)}
      {_doc, _rest} -> {:error, :unparsed_remainder}
    end
  catch
    :exit, reason -> {:error, {:parse_failure, reason}}
    :error, reason -> {:error, {:parse_failure, reason}}
  end

  defp normalize(doc) do
    doc |> :xmerl_lib.simplify_element() |> normalize_element()
  end

  defp normalize_element({tag, attrs, children}) do
    {to_string(tag), normalize_attrs(attrs), normalize_children(children)}
  end

  defp normalize_attrs(attrs) do
    Map.new(attrs, fn {name, value} -> {to_string(name), to_string(value)} end)
  end

  defp normalize_children(children) when is_list(children) do
    children
    |> Enum.flat_map(fn
      {tag, attrs, kids} -> [normalize_element({tag, attrs, kids})]
      text when is_list(text) -> [trim_text(to_string(text))]
      text when is_binary(text) -> [trim_text(text)]
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp trim_text(text) do
    text
    |> String.trim_leading()
    |> String.trim_trailing()
  end

  @doc "Serialize an element tree to an XML document with declaration."
  @spec serialize(element()) :: String.t()
  def serialize({_name, _attrs, _children} = root) do
    ~s(<?xml version="1.0" encoding="UTF-8"?>\n) <> XmlBuilder.generate(to_xb(root))
  end

  defp to_xb({name, attrs, children}) do
    attr_map = if attrs == %{}, do: nil, else: attrs
    {safe_tag(name), attr_map, Enum.map(children, &child_to_xb/1)}
  end

  defp child_to_xb({name, attrs, children} = _element), do: to_xb({name, attrs, children})
  defp child_to_xb(text) when is_binary(text), do: text

  defp safe_tag(name) when is_binary(name), do: name

  @doc """
  Extract CAP fields from a parsed `<alert>` element. Unknown child elements of
  `<alert>` are returned as alert extensions; unknown children of each `<info>`
  are attached to that info as `info_extensions`. Multiple `<info>` segments
  are collected in document order.
  """
  @spec extract_cap(element()) :: {:ok, cap_fields()} | {:error, term()}
  def extract_cap({"alert", _attrs, children} = _element) do
    alert_kids = Enum.filter(children, &is_tuple/1)

    info_elements = Enum.filter(alert_kids, fn {name, _, _} -> name == "info" end)

    {known_alert, alert_extensions} =
      alert_kids
      |> Enum.reject(fn {name, _, _} -> name == "info" end)
      |> Enum.split_with(fn {name, _, _} -> name in alert_extracted_names() end)

    fields =
      %{}
      |> put_alert_known(known_alert)
      |> Map.put(:infos, Enum.map(info_elements, &extract_info/1))
      |> Map.put(:alert_extensions, alert_extensions)

    {:ok, fields}
  end

  def extract_cap(_element), do: {:error, :not_an_alert}

  defp alert_extracted_names do
    ~w(identifier sender sent status msgType scope references)
  end

  defp info_extracted_names do
    ~w(language event urgency severity certainty headline description instruction area)
  end

  defp put_alert_known(fields, kids) do
    Enum.reduce(kids, fields, fn
      {"identifier", _, [text | _]}, acc ->
        Map.put(acc, :identifier, text_content(text))

      {"sender", _, [text | _]}, acc ->
        Map.put(acc, :sender, text_content(text))

      {"sent", _, [text | _]}, acc ->
        Map.put(acc, :sent, text_content(text))

      {"status", _, [text | _]}, acc ->
        put_enum(acc, :status, text, &Enums.parse_cap_status/1)

      {"msgType", _, [text | _]}, acc ->
        put_enum(acc, :msg_type, text, &Enums.parse_cap_msg_type/1)

      {"scope", _, [text | _]}, acc ->
        put_enum(acc, :scope, text, &Enums.parse_cap_scope/1)

      {"references", _, [text | _]}, acc ->
        Map.put(acc, :references, text_content(text))

      _, acc ->
        acc
    end)
  end

  defp extract_info({"info", _, children}) do
    kids = Enum.filter(children, &is_tuple/1)

    {known_info, info_extensions} =
      Enum.split_with(kids, fn {name, _, _} -> name in info_extracted_names() end)

    %{}
    |> put_info_known(known_info)
    |> Map.put(:info_extensions, info_extensions)
  end

  defp put_info_known(fields, kids) do
    Enum.reduce(kids, fields, fn
      {"language", _, [text | _]}, acc ->
        Map.put(acc, :language, text_content(text))

      {"event", _, [text | _]}, acc ->
        Map.put(acc, :event, text_content(text))

      {"headline", _, [text | _]}, acc ->
        Map.put(acc, :headline, text_content(text))

      {"description", _, [text | _]}, acc ->
        Map.put(acc, :description, text_content(text))

      {"instruction", _, [text | _]}, acc ->
        Map.put(acc, :instruction, text_content(text))

      {"urgency", _, [text | _]}, acc ->
        put_enum(acc, :urgency, text, &Enums.parse_cap_urgency/1)

      {"severity", _, [text | _]}, acc ->
        put_enum(acc, :severity, text, &Enums.parse_cap_severity/1)

      {"certainty", _, [text | _]}, acc ->
        put_enum(acc, :certainty, text, &Enums.parse_cap_certainty/1)

      {"area", _, area_children}, acc ->
        put_area(acc, area_children)

      _, acc ->
        acc
    end)
  end

  defp put_area(fields, children) do
    kids = Enum.filter(children, &is_tuple/1)

    fields =
      case Enum.find(kids, fn {name, _, _} -> name == "areaDesc" end) do
        {"areaDesc", _, [text | _]} -> Map.put(fields, :area_desc, text_content(text))
        _ -> fields
      end

    geocodes =
      kids
      |> Enum.filter(fn {name, _, _} -> name == "geocode" end)
      |> Enum.map(fn {"geocode", _, gc_children} ->
        gc = Enum.filter(gc_children, &is_tuple/1)
        value_name = child_text(gc, "valueName")
        value = child_text(gc, "value")
        %{value_name: value_name, value: value}
      end)

    Map.put(fields, :geocodes, geocodes)
  end

  defp child_text(kids, name) do
    case Enum.find(kids, fn {n, _, _} -> n == name end) do
      {^name, _, [text | _]} -> text_content(text)
      _ -> ""
    end
  end

  defp text_content(text) when is_binary(text), do: text
  defp text_content(text) when is_list(text), do: to_string(text)

  defp put_enum(acc, key, text, parser) do
    case parser.(text_content(text)) do
      {:ok, atom} -> Map.put(acc, key, atom)
      :error -> acc
    end
  end

  @doc """
  Build a CAP `<alert>` element tree from the given field map. Known fields are
  emitted in CAP order followed by preserved extension elements, then one
  `<info>` element per entry in `infos`.
  """
  @spec build_cap(cap_fields()) :: element()
  def build_cap(fields) do
    alert_known =
      [
        text_elem("identifier", fields[:identifier]),
        text_elem("sender", fields[:sender]),
        text_elem("sent", format_sent(fields[:sent])),
        enum_elem("status", fields[:status], &Enums.cap_status_string/1),
        enum_elem("msgType", fields[:msg_type], &Enums.cap_msg_type_string/1),
        text_elem("scope", enum_str(fields[:scope], &Enums.cap_scope_string/1)),
        text_elem("references", fields[:references])
      ]
      |> Enum.reject(&is_nil/1)

    infos = Enum.map(fields[:infos] || [], &build_info/1)

    children =
      alert_known ++
        Enum.filter(fields[:alert_extensions] || [], &is_tuple/1) ++
        infos

    {"alert", %{"xmlns" => @cap_ns}, children}
  end

  defp build_info(info) do
    known =
      [
        text_elem("language", info[:language]),
        text_elem("event", info[:event]),
        enum_elem("urgency", info[:urgency], &Enums.cap_urgency_string/1),
        enum_elem("severity", info[:severity], &Enums.cap_severity_string/1),
        enum_elem("certainty", info[:certainty], &Enums.cap_certainty_string/1),
        text_elem("headline", info[:headline]),
        text_elem("description", info[:description]),
        text_elem("instruction", info[:instruction])
      ]
      |> Enum.reject(&is_nil/1)

    area =
      if info[:geocodes] not in [nil, []] or info[:area_desc] not in [nil, ""] do
        [build_area(info)]
      else
        []
      end

    extensions = Enum.filter(info[:info_extensions] || [], &is_tuple/1)

    {"info", %{}, known ++ extensions ++ area}
  end

  defp build_area(info) do
    area_desc =
      case info[:area_desc] do
        nil -> []
        "" -> []
        desc -> [text_elem("areaDesc", desc)]
      end

    geocodes =
      Enum.map(info[:geocodes] || [], fn gc ->
        {"geocode", %{},
         [
           text_elem("valueName", gc[:value_name] || gc["value_name"]),
           text_elem("value", gc[:value] || gc["value"])
         ]}
      end)

    {"area", %{}, area_desc ++ geocodes}
  end

  defp text_elem(_name, nil), do: nil
  defp text_elem(_name, ""), do: nil
  defp text_elem(name, value), do: {name, %{}, [to_string(value)]}

  defp enum_elem(_name, nil, _fun), do: nil
  defp enum_elem(name, atom, fun), do: {name, %{}, [fun.(atom)]}

  defp enum_str(nil, _fun), do: nil
  defp enum_str(atom, fun), do: fun.(atom)

  defp format_sent(nil), do: nil
  defp format_sent(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_sent(s) when is_binary(s), do: s

  @doc """
  Convenience: parse + extract.
  """
  @spec decode(String.t()) :: {:ok, cap_fields(), element()} | {:error, term()}
  def decode(xml) do
    with {:ok, element} <- parse(xml),
         {:ok, fields} <- extract_cap(element) do
      {:ok, fields, element}
    end
  end

  @doc """
  Convenience: build + serialize.
  """
  @spec encode(cap_fields()) :: String.t()
  def encode(fields), do: fields |> build_cap() |> serialize()

  # ---------------------------------------------------------------------------
  # JSON-safe element conversion (for jsonb storage of extension elements)
  # ---------------------------------------------------------------------------

  @doc "Convert a simple-form element tree into a JSON-encodable map."
  @spec element_to_map(element()) :: map()
  def element_to_map({name, attrs, children}) do
    %{
      "name" => name,
      "attrs" => attrs,
      "children" => Enum.map(children, &child_to_json/1)
    }
  end

  defp child_to_json({name, attrs, children} = _el),
    do: element_to_map({name, attrs, children})

  defp child_to_json(text) when is_binary(text), do: text

  @doc "Convert a JSON map back into a simple-form element tree."
  @spec element_from_map(map()) :: element()
  def element_from_map(%{"name" => name, "attrs" => attrs, "children" => children}) do
    {name, attrs || %{}, Enum.map(children || [], &child_from_json/1)}
  end

  defp child_from_json(%{"name" => _} = map), do: element_from_map(map)
  defp child_from_json(text) when is_binary(text), do: text
end
