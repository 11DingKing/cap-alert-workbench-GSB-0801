defmodule CapWorkbenchWeb.Api.MessageController do
  @moduledoc """
  JSON API backing the CAP alert workflow.

  Every mutating action delegates to `CapWorkbench.Alerts` use-cases — the same
  domain entry points used by the LiveView. The controller never touches Repo or
  state fields directly. Domain error atoms are mapped to appropriate HTTP
  statuses (409 for concurrency/duplicate conflicts, 422 for validation, etc).
  """
  use CapWorkbenchWeb, :controller

  alias CapWorkbench.Alerts
  alias CapWorkbench.Cap.{Enums, Xml}

  action_fallback CapWorkbenchWeb.Api.FallbackController

  def index(conn, _params) do
    messages = Alerts.list_messages()
    json(conn, %{data: Enum.map(messages, &message_json/1)})
  end

  def show(conn, %{"id" => id}) do
    case Alerts.get_message(id) do
      nil -> {:error, :not_found}
      message -> json(conn, %{data: message_json(message, :full)})
    end
  end

  def create(conn, %{"message" => params}) do
    with {:ok, attrs} <- cast_content(params),
         {:ok, message} <- Alerts.create_message(attrs, actor(conn)) do
      conn
      |> put_status(:created)
      |> json(%{data: message_json(message, :full)})
    end
  end

  def save_version(conn, %{"id" => id, "version" => params, "lock_version" => lock}) do
    with %{} = message <- fetch(id),
         {:ok, attrs} <- cast_content(params, :partial),
         {:ok, updated} <- Alerts.save_new_version(message, attrs, lock, actor(conn)) do
      json(conn, %{data: message_json(updated, :full)})
    end
  end

  def submit(conn, %{"id" => id, "lock_version" => lock}) do
    with %{} = message <- fetch(id),
         latest when not is_nil(latest) <- Alerts.latest_version(message),
         {:ok, updated} <- Alerts.submit_for_review(message, latest, lock, actor(conn)) do
      json(conn, %{data: message_json(updated, :full)})
    end
  end

  def review(conn, %{"id" => id, "decision" => decision, "lock_version" => lock} = params) do
    with %{} = message <- fetch(id),
         latest when not is_nil(latest) <- Alerts.latest_version(message),
         {:ok, decision_atom} <- cast_decision(decision),
         {:ok, updated} <-
           Alerts.review(message, latest, decision_atom, actor(conn), params["comment"], lock) do
      json(conn, %{data: message_json(updated, :full)})
    end
  end

  def publish(conn, %{"id" => id, "lock_version" => lock}) do
    with %{} = message <- fetch(id),
         latest when not is_nil(latest) <- Alerts.latest_version(message),
         {:ok, updated} <- Alerts.publish(message, latest, lock, actor(conn)) do
      json(conn, %{data: message_json(updated, :full)})
    end
  end

  def correction(conn, %{"id" => id} = params) do
    with %{} = message <- fetch(id),
         {:ok, overrides} <- cast_overrides(params["overrides"]),
         {:ok, new_message} <- Alerts.create_correction(message, overrides, actor(conn)) do
      conn
      |> put_status(:created)
      |> json(%{data: message_json(new_message, :full)})
    end
  end

  def cancellation(conn, %{"id" => id} = params) do
    with %{} = message <- fetch(id),
         {:ok, overrides} <- cast_overrides(params["overrides"]),
         {:ok, new_message} <- Alerts.create_cancellation(message, overrides, actor(conn)) do
      conn
      |> put_status(:created)
      |> json(%{data: message_json(new_message, :full)})
    end
  end

  def export(conn, %{"id" => id}) do
    with %{} = message <- fetch(id) do
      version = published_or_latest(message)

      xml = Xml.encode(message, version)

      conn
      |> put_resp_content_type("application/xml")
      |> send_resp(200, xml)
    end
  end

  def import(conn, %{"xml" => xml}) when is_binary(xml) do
    with {:ok, parsed} <- Xml.decode(xml),
         attrs <- Map.merge(parsed.message, parsed.version),
         {:ok, message} <- Alerts.create_message(attrs, actor(conn)) do
      conn
      |> put_status(:created)
      |> json(%{data: message_json(message, :full), extensions: parsed.version.extensions})
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp fetch(id) do
    case Alerts.get_message(id) do
      nil -> {:error, :not_found}
      message -> message
    end
  end

  defp published_or_latest(message) do
    Enum.find(message.versions, &(&1.id == message.published_version_id)) ||
      List.last(message.versions)
  end

  defp actor(conn) do
    case get_req_header(conn, "x-actor") do
      [actor | _] when actor != "" -> actor
      _ -> "api"
    end
  end

  # Casts external JSON into the domain attribute map. Enum labels are resolved
  # against the whitelisted `Enums` values — unknown values become nil so the
  # changeset returns a validation error (never String.to_atom on user input).
  #
  # `params["infos"]` is a list of info-block maps; each is normalized here.
  defp cast_content(params, mode \\ :full) do
    envelope =
      %{
        identifier: params["identifier"],
        sender: params["sender"],
        sent_at: parse_dt(params["sent_at"]),
        status: enum(:status, params["status"]),
        msg_type: enum(:msg_type, params["msg_type"]),
        scope: enum(:scope, params["scope"]),
        extensions: params["extensions"] || %{}
      }

    envelope = if mode == :partial, do: drop_nil(envelope), else: envelope

    attrs =
      case params["infos"] do
        infos when is_list(infos) -> Map.put(envelope, :infos, Enum.map(infos, &cast_info/1))
        _ -> envelope
      end

    {:ok, attrs}
  end

  defp cast_info(info) do
    %{
      "language" => info["language"] || "zh-CN",
      "category" => enum(:category, info["category"]),
      "event" => info["event"],
      "urgency" => enum(:urgency, info["urgency"]),
      "severity" => enum(:severity, info["severity"]),
      "certainty" => enum(:certainty, info["certainty"]),
      "headline" => info["headline"],
      "description" => info["description"],
      "instruction" => info["instruction"],
      "area_description" => info["area_description"],
      "geocodes" => info["geocodes"] || [],
      "effective_at" => parse_dt(info["effective_at"]),
      "onset_at" => parse_dt(info["onset_at"]),
      "expires_at" => parse_dt(info["expires_at"]),
      "extensions" => info["extensions"] || %{}
    }
  end

  # Correction/cancellation overrides: either explicit `infos`, or region-keyed
  # severity/headline/description maps that the domain uses to split regions.
  defp cast_overrides(nil), do: {:ok, %{}}

  defp cast_overrides(overrides) when is_map(overrides) do
    result =
      %{}
      |> put_if_present(:region_severities, overrides["region_severities"])
      |> put_if_present(:region_headlines, overrides["region_headlines"])
      |> put_if_present(:region_descriptions, overrides["region_descriptions"])

    result =
      case overrides["infos"] do
        infos when is_list(infos) -> Map.put(result, :infos, Enum.map(infos, &cast_info/1))
        _ -> result
      end

    {:ok, result}
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp drop_nil(map), do: Enum.reject(map, fn {_k, v} -> is_nil(v) end) |> Map.new()

  defp cast_decision("approve"), do: {:ok, :approve}
  defp cast_decision("reject"), do: {:ok, :reject}
  defp cast_decision(_), do: {:error, :invalid_decision}

  defp enum(_field, nil), do: nil
  defp enum(_field, ""), do: nil

  defp enum(field, value) do
    case Enums.from_cap_token(field, value) do
      {:ok, atom} ->
        atom

      :error ->
        # Also accept lowercase atom-name form (e.g. "immediate").
        apply(Enums, plural(field), [])
        |> Enum.find(fn atom -> Atom.to_string(atom) == value end)
    end
  end

  defp plural(:status), do: :statuses
  defp plural(:msg_type), do: :msg_types
  defp plural(:scope), do: :scopes
  defp plural(:category), do: :categories
  defp plural(:urgency), do: :urgencies
  defp plural(:severity), do: :severities
  defp plural(:certainty), do: :certainties

  defp parse_dt(nil), do: nil
  defp parse_dt(""), do: nil

  defp parse_dt(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp message_json(message, mode \\ :summary)

  defp message_json(message, :summary) do
    %{
      id: message.id,
      identifier: message.identifier,
      msg_type: message.msg_type,
      status: message.status,
      scope: message.scope,
      workflow_state: message.workflow_state,
      lock_version: message.lock_version,
      version_count: length(message.versions)
    }
  end

  defp message_json(message, :full) do
    message
    |> message_json(:summary)
    |> Map.merge(%{
      sender: message.sender,
      sent_at: message.sent_at,
      references_text: message.references_text,
      references_message_id: message.references_message_id,
      published_version_id: message.published_version_id,
      versions: Enum.map(message.versions, &version_json/1)
    })
  end

  defp version_json(v) do
    %{
      id: v.id,
      version_number: v.version_number,
      review_state: v.review_state,
      published: v.published,
      extensions: v.extensions,
      infos: Enum.map(v.infos, &info_json/1),
      reviewed_by: v.reviewed_by,
      reviewed_at: v.reviewed_at,
      published_at: v.published_at
    }
  end

  defp info_json(info) do
    %{
      id: info.id,
      language: info.language,
      category: info.category,
      event: info.event,
      urgency: info.urgency,
      severity: info.severity,
      certainty: info.certainty,
      headline: info.headline,
      description: info.description,
      instruction: info.instruction,
      area_description: info.area_description,
      geocodes: info.geocodes,
      extensions: info.extensions,
      effective_at: info.effective_at,
      onset_at: info.onset_at,
      expires_at: info.expires_at
    }
  end
end
