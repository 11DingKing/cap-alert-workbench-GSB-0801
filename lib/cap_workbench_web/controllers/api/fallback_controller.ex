defmodule CapWorkbenchWeb.Api.FallbackController do
  @moduledoc """
  Translates domain and controller error tuples into JSON HTTP responses.

  Concurrency and idempotency conflicts map to `409 Conflict` so API clients can
  distinguish "reload and retry" situations from validation failures (`422`).
  """
  use CapWorkbenchWeb, :controller

  # Optimistic-lock / stale-review / duplicate publish -> 409 Conflict.
  def call(conn, {:error, reason})
      when reason in [:stale, :stale_review, :duplicate_publish, :already_published] do
    conn
    |> put_status(:conflict)
    |> json(%{error: %{code: reason, message: message_for(reason)}})
  end

  def call(conn, {:error, reason})
      when reason in [
             :not_publishable,
             :not_submittable,
             :not_latest_version,
             :not_editable,
             :not_published,
             :invalid_decision
           ] do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: reason, message: message_for(reason)}})
  end

  def call(conn, {:error, {:illegal_transition, state, event}}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        code: :illegal_transition,
        message: "illegal transition #{event} from #{state}"
      }
    })
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: :not_found, message: "resource not found"}})
  end

  # XML parse / import errors -> 422.
  def call(conn, {:error, reason})
      when reason in [:doctype_forbidden, :missing_info, :not_a_cap_alert] do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: reason, message: message_for(reason)}})
  end

  def call(conn, {:error, {:malformed_xml, detail}}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: :malformed_xml, message: detail}})
  end

  def call(conn, {:error, {tag, name} = reason})
      when tag in [:invalid_token, :missing_field] do
    _ = reason

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: tag, message: "#{tag}: #{inspect(name)}"}})
  end

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: :validation, details: changeset_errors(changeset)}})
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp message_for(:stale), do: "optimistic lock conflict; reload and retry"
  defp message_for(:stale_review), do: "review decision is stale; re-review the latest version"
  defp message_for(:duplicate_publish), do: "duplicate publish suppressed"
  defp message_for(:already_published), do: "message already published"
  defp message_for(:not_publishable), do: "only the latest approved version can be published"

  defp message_for(:not_submittable),
    do: "message cannot be submitted for review in its current state"

  defp message_for(:not_latest_version), do: "a newer draft version exists"
  defp message_for(:not_editable), do: "message content is frozen"
  defp message_for(:not_published), do: "only a published message can be corrected or cancelled"
  defp message_for(:invalid_decision), do: "decision must be approve or reject"
  defp message_for(:doctype_forbidden), do: "DOCTYPE declarations are not allowed"
  defp message_for(:missing_info), do: "CAP <info> element missing"
  defp message_for(:not_a_cap_alert), do: "document root is not a CAP <alert>"
end
