defmodule CapWorkbenchWeb.MessageLive.Index do
  @moduledoc """
  Lists all CAP alert messages and hosts the "new draft" form.

  This LiveView only calls `CapWorkbench.Alerts` use-cases; it never touches
  workflow/state fields or the Repo directly.
  """
  use CapWorkbenchWeb, :live_view

  alias CapWorkbench.Alerts
  alias CapWorkbench.Cap.{DraftVersion, Enums}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Alerts.subscribe_all()

    {:ok,
     socket
     |> assign(:page_title, "预警编审工作台")
     |> load_messages()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "新建预警草稿")
    |> assign(:form, new_form())
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, :form, nil)
  end

  @impl true
  def handle_event("validate", %{"draft" => params}, socket) do
    form =
      %DraftVersion{}
      |> Alerts.change_version(params)
      |> Map.put(:action, :validate)
      |> to_form(as: :draft)

    {:noreply, assign(socket, :form, merge_params(form, params))}
  end

  def handle_event("create", %{"draft" => params}, socket) do
    attrs = normalize_params(params)

    case Alerts.create_message(attrs, "值班员") do
      {:ok, message} ->
        {:noreply,
         socket
         |> put_flash(:info, "草稿已创建：#{message.identifier}")
         |> push_navigate(to: ~p"/messages/#{message.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :draft))}
    end
  end

  @impl true
  def handle_info({:messages_changed, _id, _event}, socket) do
    {:noreply, load_messages(socket)}
  end

  defp load_messages(socket) do
    assign(socket, :messages, Alerts.list_messages())
  end

  defp new_form do
    %DraftVersion{}
    |> Alerts.change_version(%{})
    |> to_form(as: :draft)
  end

  # Keep raw string params (envelope + content) available to re-render the form.
  defp merge_params(form, params), do: %{form | params: params}

  defp normalize_params(params) do
    %{
      identifier: params["identifier"],
      sender: params["sender"] || Alerts.default_sender(),
      sent_at: parse_dt(params["sent_at"]),
      status: to_enum(params["status"]),
      msg_type: to_enum(params["msg_type"]),
      scope: to_enum(params["scope"]),
      language: params["language"] || "zh-CN",
      category: to_enum(params["category"]),
      event: params["event"],
      urgency: to_enum(params["urgency"]),
      severity: to_enum(params["severity"]),
      certainty: to_enum(params["certainty"]),
      headline: params["headline"],
      description: params["description"],
      instruction: params["instruction"],
      area_description: params["area_description"],
      geocodes: split_geocodes(params["geocodes"])
    }
  end

  # Only maps a known enum label; unknown/blank input becomes nil so the
  # changeset surfaces a validation error rather than crashing.
  defp to_enum(nil), do: nil
  defp to_enum(""), do: nil

  defp to_enum(value) do
    all =
      Enums.statuses() ++
        Enums.msg_types() ++
        Enums.scopes() ++
        Enums.categories() ++
        Enums.urgencies() ++ Enums.severities() ++ Enums.certainties()

    Enum.find(all, fn atom -> Atom.to_string(atom) == value end)
  end

  defp split_geocodes(nil), do: []

  defp split_geocodes(value) do
    value
    |> String.split([",", " ", "\n", "，"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_dt(nil), do: nil
  defp parse_dt(""), do: nil

  defp parse_dt(value) do
    # datetime-local yields e.g. "2026-07-29T08:00"
    case NaiveDateTime.from_iso8601(value <> ":00") do
      {:ok, naive} ->
        DateTime.from_naive!(naive, "Etc/UTC")

      _ ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _} -> dt
          _ -> nil
        end
    end
  end

  # --- template helpers ------------------------------------------------------

  @doc false
  def enum_options(kind) do
    apply(Enums, kind, []) |> Enum.map(fn atom -> {label_for(atom), Atom.to_string(atom)} end)
  end

  defp label_for(atom), do: Atom.to_string(atom)

  def workflow_label(:drafting), do: "草稿"
  def workflow_label(:in_review), do: "复核中"
  def workflow_label(:published), do: "已发布"
  def workflow_label(:superseded), do: "已被更正/解除"

  def workflow_badge(:drafting), do: "badge-ghost"
  def workflow_badge(:in_review), do: "badge-warning"
  def workflow_badge(:published), do: "badge-success"
  def workflow_badge(:superseded), do: "badge-neutral"
end
