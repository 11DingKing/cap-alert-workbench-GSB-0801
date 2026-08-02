defmodule CapAlertWorkbench.Cap.Xml.SaxTreeBuilder do
  @moduledoc """
  Event function for `:xmerl_sax_parser.stream/2` that builds a simple node
  tree and hard-fails on DTD, entity, notation, or external entity events.

  Using an event function (instead of a DOM parser) means external entities are
  never resolved by default. We additionally throw on any DTD-related event so
  that even internal entity declarations are rejected.
  """

  @type xml_node :: %{
          name: String.t(),
          ns: String.t(),
          attrs: %{String.t() => String.t()},
          children: [String.t() | xml_node()]
        }

  @type state :: %{stack: [xml_node()], root: xml_node() | nil}

  @spec initial_state() :: state()
  def initial_state, do: %{stack: [], root: nil}

  @doc "Entry point used as the `:event_fun` for xmerl_sax_parser."
  def event(:startDocument, _loc, state), do: state
  def event(:endDocument, _loc, state), do: state

  def event({:startElement, uri, local, qname, attrs}, _loc, state) do
    node = %{
      name: element_name(local, qname),
      ns: to_string(uri),
      attrs: attr_map(attrs),
      children: []
    }

    %{state | stack: [node | state.stack]}
  end

  def event({:endElement, _uri, local, qname}, _loc, state) do
    name = element_name(local, qname)

    case state.stack do
      [%{name: ^name} = node | rest] ->
        completed = %{node | children: node.children}

        case rest do
          [] ->
            %{state | stack: [], root: completed}

          [parent | grand_rest] ->
            updated_parent = %{parent | children: parent.children ++ [completed]}
            %{state | stack: [updated_parent | grand_rest]}
        end

      _ ->
        throw({:fatal_error, :mismatched_end_element})
    end
  end

  def event({:characters, chars}, _loc, state) do
    text = to_string(chars)

    case state.stack do
      [current | rest] ->
        updated = %{current | children: current.children ++ [text]}
        %{state | stack: [updated | rest]}

      [] ->
        state
    end
  end

  def event({:ignorableWhitespace, _chars}, _loc, state), do: state

  def event({:startPrefixMapping, _prefix, _uri}, _loc, state), do: state
  def event({:endPrefixMapping, _prefix}, _loc, state), do: state
  def event({:processingInstruction, _target, _data}, _loc, state), do: state
  def event({:comment, _comment}, _loc, state), do: state
  def event({:startCDATA}, _loc, state), do: state
  def event({:endCDATA}, _loc, state), do: state

  def event({:startDTD, _name, _pub, _sys}, _loc, _state),
    do: throw({:fatal_error, :doctype_not_permitted})

  def event({:endDTD}, _loc, state), do: state

  def event({:startEntity, _name}, _loc, _state),
    do: throw({:fatal_error, :entity_not_permitted})

  def event({:endEntity, _name}, _loc, state), do: state

  def event({:unparsedEntityDecl, _decl}, _loc, _state),
    do: throw({:fatal_error, :entity_not_permitted})

  def event({:notationDecl, _decl}, _loc, _state),
    do: throw({:fatal_error, :notation_not_permitted})

  def event({:externalEntityDecl, _decl}, _loc, _state),
    do: throw({:fatal_error, :external_entity_not_permitted})

  def event({:internalEntityDecl, _decl}, _loc, state), do: state
  def event({:elementDecl, _decl}, _loc, state), do: state
  def event({:attributeDecl, _decl}, _loc, state), do: state

  def event(_other, _loc, state), do: state

  defp attr_map(attrs) when is_list(attrs) do
    Enum.into(attrs, %{}, fn
      {_uri, _prefix, name, value} -> {to_string(name), to_string(value)}
    end)
  end

  defp attr_map(_), do: %{}

  defp element_name(local, {[], _local}), do: to_string(local)
  defp element_name(_local, {prefix, local}), do: "#{to_string(prefix)}:#{to_string(local)}"
  defp element_name(local, _qname), do: to_string(local)
end
