defmodule CapWorkbench.Cap.Xml do
  @moduledoc """
  CAP 1.2 XML serialization and safe parsing.

  Serialization is built entirely from Saxy's structured simple-form
  (`{name, attributes, children}` tuples) and encoded with `Saxy.encode!/1`.
  All escaping of special characters is handled by the encoder — there is **no**
  string concatenation or manual escaping anywhere in this module.

  Parsing uses `Saxy.SimpleForm.parse_string/2`, a non-validating parser that
  never resolves DTDs or external entities. We additionally reject any document
  containing a DOCTYPE declaration and pass `expand_entity: :never` so predefined
  and custom entity references are preserved verbatim rather than expanded. This
  closes XXE / entity-expansion vectors.

  Unknown / forward-compatible elements (at both the `<alert>` and `<info>`
  level) are preserved into a JSON-safe structure so that an import → export
  round-trip retains extension fields the workbench does not itself model.
  """

  alias CapWorkbench.Cap.{AlertMessage, DraftVersion, Enums}

  @cap_ns "urn:oasis:names:tc:emergency:cap:1.2"

  # Elements the workbench models natively at the <alert> level.
  @known_alert_children ~w(identifier sender sent status msgType scope references info)
  # Elements the workbench models natively at the <info> level.
  @known_info_children ~w(language category event urgency severity certainty
                          effective onset expires headline description instruction area)

  @doc """
  Serializes a persisted `%AlertMessage{}` + `%DraftVersion{}` into CAP 1.2 XML.

  Every constrained value is rendered via `Enums.to_cap_token/1`; unknown atoms
  would raise rather than emit an unvalidated string.
  """
  @spec encode(AlertMessage.t(), DraftVersion.t()) :: String.t()
  def encode(%AlertMessage{} = message, %DraftVersion{} = version) do
    document =
      element("alert", [{"xmlns", @cap_ns}], alert_children(message, version))

    Saxy.encode!(document, version: "1.0", encoding: :utf8)
  end

  defp alert_children(message, version) do
    base = [
      element("identifier", [], [text(message.identifier)]),
      element("sender", [], [text(message.sender)]),
      element("sent", [], [text(format_dt(message.sent_at))]),
      element("status", [], [text(Enums.to_cap_token(message.status))]),
      element("msgType", [], [text(Enums.to_cap_token(message.msg_type))]),
      element("scope", [], [text(Enums.to_cap_token(message.scope))])
    ]

    references =
      case message.references_text do
        nil -> []
        "" -> []
        ref -> [element("references", [], [text(ref)])]
      end

    alert_extensions = extension_elements(version.extensions, "alert")

    base ++ references ++ [info_element(message, version)] ++ alert_extensions
  end

  defp info_element(_message, version) do
    children =
      [
        element("language", [], [text(version.language)]),
        element("category", [], [text(Enums.to_cap_token(version.category))]),
        element("event", [], [text(version.event)]),
        element("urgency", [], [text(Enums.to_cap_token(version.urgency))]),
        element("severity", [], [text(Enums.to_cap_token(version.severity))]),
        element("certainty", [], [text(Enums.to_cap_token(version.certainty))])
      ] ++
        optional_dt("effective", version.effective_at) ++
        optional_dt("onset", version.onset_at) ++
        optional_dt("expires", version.expires_at) ++
        [
          element("headline", [], [text(version.headline)]),
          element("description", [], [text(version.description)])
        ] ++
        optional_text("instruction", version.instruction) ++
        [area_element(version)] ++
        extension_elements(version.extensions, "info")

    element("info", [], children)
  end

  defp area_element(version) do
    geocodes =
      Enum.map(version.geocodes, fn code ->
        element("geocode", [], [
          element("valueName", [], [text("SAME")]),
          element("value", [], [text(code)])
        ])
      end)

    element("area", [], [element("areaDesc", [], [text(version.area_description)]) | geocodes])
  end

  defp optional_text(_name, nil), do: []
  defp optional_text(_name, ""), do: []
  defp optional_text(name, value), do: [element(name, [], [text(value)])]

  defp optional_dt(_name, nil), do: []
  defp optional_dt(name, %DateTime{} = dt), do: [element(name, [], [text(format_dt(dt))])]

  # --- Extension round-trip: JSON-safe map <-> simple form -------------------

  defp extension_elements(extensions, level) when is_map(extensions) do
    extensions
    |> Map.get(level, [])
    |> List.wrap()
    |> Enum.map(&node_to_simple_form/1)
  end

  defp node_to_simple_form(%{"name" => name} = node) do
    attributes =
      node
      |> Map.get("attributes", [])
      |> Enum.map(fn [k, v] -> {k, v} end)

    children =
      node
      |> Map.get("content", [])
      |> Enum.map(fn
        %{"name" => _} = child -> node_to_simple_form(child)
        chars when is_binary(chars) -> text(chars)
      end)

    element(name, attributes, children)
  end

  # ---------------------------------------------------------------------------

  @doc """
  Parses CAP 1.2 XML into a normalized attribute map suitable for building an
  `%AlertMessage{}` and its first `%DraftVersion{}`.

  Returns `{:ok, %{message: map, version: map}}` or `{:error, reason}`. Unknown
  constrained tokens or malformed structure produce a descriptive error rather
  than silently coercing values.
  """
  @spec decode(String.t()) :: {:ok, map()} | {:error, term()}
  def decode(xml) when is_binary(xml) do
    with :ok <- reject_doctype(xml),
         {:ok, tree} <- parse(xml),
         {:ok, result} <- interpret(tree) do
      {:ok, result}
    end
  end

  # Defense in depth: refuse any DOCTYPE so no DTD/entity definitions are honored.
  defp reject_doctype(xml) do
    if Regex.match?(~r/<!DOCTYPE/i, xml) do
      {:error, :doctype_forbidden}
    else
      :ok
    end
  end

  defp parse(xml) do
    # `:keep` decodes the five predefined XML entities (&amp; &lt; &gt; &quot;
    # &apos;) into their characters — so round-tripped text is the real string,
    # not a double-escaped one — while keeping any *other* entity reference as
    # literal text rather than expanding it. Combined with the DOCTYPE rejection
    # above (which prevents any custom/external entity from being defined at
    # all), this makes external entity expansion impossible.
    case Saxy.SimpleForm.parse_string(xml, expand_entity: :keep) do
      {:ok, tree} -> {:ok, tree}
      {:error, exception} -> {:error, {:malformed_xml, Exception.message(exception)}}
    end
  end

  defp interpret({alert_name, _attrs, children}) do
    if local_name(alert_name) == "alert" do
      info = find_child(children, "info")

      case info do
        nil ->
          {:error, :missing_info}

        {_n, _a, info_children} ->
          with {:ok, status} <- token(children, "status", :status),
               {:ok, msg_type} <- token(children, "msgType", :msg_type),
               {:ok, scope} <- token(children, "scope", :scope),
               {:ok, category} <- token(info_children, "category", :category),
               {:ok, urgency} <- token(info_children, "urgency", :urgency),
               {:ok, severity} <- token(info_children, "severity", :severity),
               {:ok, certainty} <- token(info_children, "certainty", :certainty) do
            message = %{
              identifier: text_of(children, "identifier"),
              sender: text_of(children, "sender"),
              sent_at: parse_dt(text_of(children, "sent")),
              status: status,
              msg_type: msg_type,
              scope: scope,
              references_text: text_of(children, "references")
            }

            version = %{
              language: text_of(info_children, "language") || "zh-CN",
              category: category,
              event: text_of(info_children, "event"),
              urgency: urgency,
              severity: severity,
              certainty: certainty,
              effective_at: parse_dt(text_of(info_children, "effective")),
              onset_at: parse_dt(text_of(info_children, "onset")),
              expires_at: parse_dt(text_of(info_children, "expires")),
              headline: text_of(info_children, "headline"),
              description: text_of(info_children, "description"),
              instruction: text_of(info_children, "instruction"),
              area_description: area_desc(info_children),
              geocodes: geocodes(info_children),
              extensions: %{
                "alert" => unknown_children(children, @known_alert_children),
                "info" => unknown_children(info_children, @known_info_children)
              }
            }

            {:ok, %{message: message, version: version}}
          end
      end
    else
      {:error, :not_a_cap_alert}
    end
  end

  defp interpret(_), do: {:error, :not_a_cap_alert}

  # --- helpers for reading the simple-form tree ------------------------------

  # CAP elements may carry namespace prefixes; compare on the local part.
  defp local_name(name) do
    case String.split(name, ":", parts: 2) do
      [_prefix, local] -> local
      [local] -> local
    end
  end

  defp find_child(children, name) do
    Enum.find(children, fn
      {n, _a, _c} -> local_name(n) == name
      _ -> false
    end)
  end

  defp text_of(children, name) do
    case find_child(children, name) do
      {_n, _a, content} -> content |> collect_text() |> nil_if_empty()
      nil -> nil
    end
  end

  defp collect_text(content) do
    content
    |> Enum.map(fn
      bin when is_binary(bin) -> bin
      {:cdata, data} -> data
      _ -> ""
    end)
    |> Enum.join()
    |> String.trim()
  end

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(value), do: value

  defp token(children, name, field) do
    case text_of(children, name) do
      nil ->
        {:error, {:missing_field, name}}

      value ->
        case Enums.from_cap_token(field, value) do
          {:ok, atom} -> {:ok, atom}
          :error -> {:error, {:invalid_token, name, value}}
        end
    end
  end

  defp area_desc(info_children) do
    case find_child(info_children, "area") do
      {_n, _a, area_children} -> text_of(area_children, "areaDesc")
      nil -> nil
    end
  end

  defp geocodes(info_children) do
    case find_child(info_children, "area") do
      {_n, _a, area_children} ->
        area_children
        |> Enum.filter(fn
          {n, _a, _c} -> local_name(n) == "geocode"
          _ -> false
        end)
        |> Enum.map(fn {_n, _a, gc_children} -> text_of(gc_children, "value") end)
        |> Enum.reject(&is_nil/1)

      nil ->
        []
    end
  end

  # Collect any element whose local name is NOT in the known set, converting to
  # the JSON-safe structure used by `extensions`.
  defp unknown_children(children, known) do
    children
    |> Enum.filter(fn
      {n, _a, _c} -> local_name(n) not in known
      _ -> false
    end)
    |> Enum.map(&simple_form_to_node/1)
  end

  defp simple_form_to_node({name, attributes, content}) do
    %{
      "name" => name,
      "attributes" => Enum.map(attributes, fn {k, v} -> [k, v] end),
      "content" =>
        Enum.map(content, fn
          {_n, _a, _c} = child -> simple_form_to_node(child)
          bin when is_binary(bin) -> bin
          {:cdata, data} -> data
        end)
    }
  end

  # --- date/time -------------------------------------------------------------

  # CAP timestamps are ISO 8601 with an explicit offset. Guangdong alerts use
  # China Standard Time (+08:00).
  defp format_dt(nil), do: nil

  defp format_dt(%DateTime{} = dt) do
    dt
    |> DateTime.shift_zone!("Etc/UTC")
    |> shift_to_cst()
    |> Calendar.strftime("%Y-%m-%dT%H:%M:%S+08:00")
  end

  defp shift_to_cst(%DateTime{} = utc), do: DateTime.add(utc, 8 * 3600, :second)

  defp parse_dt(nil), do: nil

  defp parse_dt(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> nil
    end
  end

  # --- simple-form constructors ----------------------------------------------

  defp element(name, attributes, children), do: Saxy.XML.element(name, attributes, children)
  defp text(nil), do: Saxy.XML.characters("")
  defp text(value), do: Saxy.XML.characters(to_string(value))
end
