defmodule CapWorkbenchWeb.MessageLive.Show do
  @moduledoc """
  The per-message workbench: draft editing, version diff, review, and publish.

  All state changes go through `CapWorkbench.Alerts`. This LiveView keeps a
  `lock_version` snapshot for optimistic concurrency; on a `{:error, :stale}`
  from any use-case it reloads and asks the operator to retry, so two browsers
  editing the same draft never silently clobber each other. It subscribes to
  the message topic so a change made elsewhere refreshes the page immediately.
  """
  use CapWorkbenchWeb, :live_view

  alias CapWorkbench.Alerts
  alias CapWorkbench.Cap.{DraftVersion, Enums, Xml}
  alias CapWorkbenchWeb.MessageLive.Index

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Alerts.subscribe(id)

    {:ok,
     socket
     |> assign(:tab, "editor")
     |> assign(:diff_from_id, nil)
     |> assign(:diff_to_id, nil)
     |> assign(:review_comment, "")
     |> assign(:xml_preview, nil)
     |> load(id)}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :tab, tab)}
  end

  # --- Draft editing: save a NEW immutable version ---------------------------

  def handle_event("validate", %{"draft" => params}, socket) do
    form =
      socket.assigns.latest
      |> Alerts.change_version(params)
      |> Map.put(:action, :validate)
      |> to_form(as: :draft)

    {:noreply, assign(socket, :form, %{form | params: params})}
  end

  def handle_event("save_version", %{"draft" => params}, socket) do
    %{message: message, latest: latest} = socket.assigns
    attrs = content_attrs(params, latest)

    case Alerts.save_new_version(
           message,
           params_to_changeset_input(attrs),
           message.lock_version,
           "值班员"
         ) do
      {:ok, _message} ->
        {:noreply,
         socket
         |> put_flash(:info, "已保存为新版本。")
         |> load(message.id)}

      {:error, :stale} ->
        {:noreply,
         socket
         |> put_flash(:error, "版本冲突：其他人刚刚修改了此草稿，已为你重新载入最新内容，请复核后重试。")
         |> load(message.id)}

      {:error, :not_editable} ->
        {:noreply, put_flash(socket, :error, "该消息已发布或被更正，无法继续编辑。")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :draft))}
    end
  end

  # --- Submit for review -----------------------------------------------------

  def handle_event("submit_for_review", _params, socket) do
    %{message: message, latest: latest} = socket.assigns

    case Alerts.submit_for_review(message, latest, message.lock_version, "值班员") do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "已提交复核。") |> load(message.id)}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, error_text(reason)) |> load(message.id)}
    end
  end

  # --- Review decisions ------------------------------------------------------

  def handle_event("set_review_comment", %{"comment" => comment}, socket) do
    {:noreply, assign(socket, :review_comment, comment)}
  end

  def handle_event("review", %{"decision" => decision}, socket) do
    %{message: message, latest: latest, review_comment: comment} = socket.assigns
    decision_atom = if decision == "approve", do: :approve, else: :reject

    case Alerts.review(message, latest, decision_atom, "复核员", comment, message.lock_version) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, if(decision_atom == :approve, do: "复核通过。", else: "已退回修改。"))
         |> assign(:review_comment, "")
         |> load(message.id)}

      {:error, :stale_review} ->
        {:noreply,
         socket
         |> put_flash(:error, "复核结论已失效：草稿已被更新，请针对最新版本重新复核。")
         |> load(message.id)}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, error_text(reason)) |> load(message.id)}
    end
  end

  # --- Publish ---------------------------------------------------------------

  def handle_event("publish", _params, socket) do
    %{message: message, latest: latest} = socket.assigns

    case Alerts.publish(message, latest, message.lock_version, "值班员") do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "已发布。内容现已冻结。") |> load(message.id)}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, error_text(reason)) |> load(message.id)}
    end
  end

  # --- Corrections / cancellations -------------------------------------------

  def handle_event("create_correction", _params, socket) do
    case Alerts.create_correction(socket.assigns.message, %{}, "值班员") do
      {:ok, new_message} ->
        {:noreply,
         socket
         |> put_flash(:info, "已基于已发布版本创建更正草稿。")
         |> push_navigate(to: ~p"/messages/#{new_message.id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_text(reason))}
    end
  end

  def handle_event("create_cancellation", _params, socket) do
    case Alerts.create_cancellation(socket.assigns.message, %{}, "值班员") do
      {:ok, new_message} ->
        {:noreply,
         socket
         |> put_flash(:info, "已基于已发布版本创建解除草稿。")
         |> push_navigate(to: ~p"/messages/#{new_message.id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_text(reason))}
    end
  end

  # --- Diff ------------------------------------------------------------------

  def handle_event("set_diff", %{"from" => from_id, "to" => to_id}, socket) do
    {:noreply, socket |> assign(:diff_from_id, from_id) |> assign(:diff_to_id, to_id)}
  end

  # --- XML preview -----------------------------------------------------------

  def handle_event("preview_xml", %{"version_id" => version_id}, socket) do
    version = Enum.find(socket.assigns.versions, &(&1.id == version_id))
    xml = Xml.encode(socket.assigns.message, version)
    {:noreply, assign(socket, :xml_preview, xml)}
  end

  def handle_event("close_xml", _params, socket) do
    {:noreply, assign(socket, :xml_preview, nil)}
  end

  # --- Live sync from other sessions -----------------------------------------

  @impl true
  def handle_info({:alert_updated, id, _event}, socket) do
    if id == socket.assigns.message.id do
      {:noreply,
       socket
       |> put_flash(:info, "该消息在另一处发生变更，已刷新。")
       |> load(id)}
    else
      {:noreply, socket}
    end
  end

  # --- Read-only version display component ------------------------------------

  attr :version, :map, required: true

  def version_readonly(assigns) do
    ~H"""
    <dl
      class="mt-4 grid grid-cols-1 md:grid-cols-2 gap-x-6 gap-y-2 text-sm"
      id={"version-readonly-#{@version.id}"}
    >
      <div>
        <dt class="text-base-content/60">标题</dt><dd class="font-medium">{@version.headline}</dd>
      </div>
      <div>
        <dt class="text-base-content/60">事件</dt><dd>{@version.event}</dd>
      </div>
      <div class="md:col-span-2">
        <dt class="text-base-content/60">描述</dt><dd class="whitespace-pre-wrap">
          {@version.description}
        </dd>
      </div>
      <div class="md:col-span-2">
        <dt class="text-base-content/60">处置建议</dt><dd class="whitespace-pre-wrap">
          {@version.instruction}
        </dd>
      </div>
      <div>
        <dt class="text-base-content/60">紧急度/严重度/确定性</dt><dd>
          {@version.urgency} · {@version.severity} · {@version.certainty}
        </dd>
      </div>
      <div>
        <dt class="text-base-content/60">类别/语言</dt><dd>{@version.category} · {@version.language}</dd>
      </div>
      <div>
        <dt class="text-base-content/60">区域描述</dt><dd>{@version.area_description}</dd>
      </div>
      <div>
        <dt class="text-base-content/60">地区编码</dt><dd class="font-mono">
          {Enum.join(@version.geocodes, ", ")}
        </dd>
      </div>
    </dl>
    """
  end

  # --- Loading / assigns -----------------------------------------------------
  defp load(socket, id) do
    message = Alerts.get_message!(id)
    versions = message.versions
    latest = List.last(versions)

    diff_from_id = socket.assigns[:diff_from_id] || default_diff_from(versions)
    diff_to_id = socket.assigns[:diff_to_id] || (latest && latest.id)

    socket
    |> assign(:page_title, message.identifier)
    |> assign(:message, message)
    |> assign(:versions, versions)
    |> assign(:latest, latest)
    |> assign(:published_version, published_version(message, versions))
    |> assign(:audit_events, Alerts.list_audit_events(message))
    |> assign(:outbox_entries, Alerts.list_outbox_entries(message))
    |> assign(:form, latest |> Alerts.change_version(%{}) |> to_form(as: :draft))
    |> assign(:diff_from_id, diff_from_id)
    |> assign(:diff_to_id, diff_to_id)
    |> assign(:diff, compute_diff(versions, diff_from_id, diff_to_id))
  end

  defp default_diff_from(versions) when length(versions) >= 2 do
    Enum.at(versions, -2).id
  end

  defp default_diff_from(versions), do: versions |> List.first() |> then(&(&1 && &1.id))

  defp published_version(%{published_version_id: nil}, _versions), do: nil

  defp published_version(%{published_version_id: pid}, versions),
    do: Enum.find(versions, &(&1.id == pid))

  defp compute_diff(versions, from_id, to_id) when is_binary(from_id) and is_binary(to_id) do
    from = Enum.find(versions, &(&1.id == from_id))
    to = Enum.find(versions, &(&1.id == to_id))

    if from && to, do: Alerts.diff_versions(from, to), else: []
  end

  defp compute_diff(_versions, _from, _to), do: []

  # Merge edited params over the latest version to form a full content map.
  defp content_attrs(params, _latest), do: params

  defp params_to_changeset_input(params) do
    params
    |> Map.update("geocodes", [], &split_geocodes/1)
    |> normalize_enum_keys()
  end

  defp normalize_enum_keys(params) do
    Enum.reduce(~w(category urgency severity certainty), params, fn key, acc ->
      case Map.get(acc, key) do
        nil -> acc
        "" -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp split_geocodes(value) when is_list(value), do: value

  defp split_geocodes(value) when is_binary(value) do
    value
    |> String.split([",", " ", "\n", "，"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # --- Guards for the template -----------------------------------------------

  def can_edit?(message), do: message.workflow_state in [:drafting, :in_review]
  def can_submit?(message, latest), do: CapWorkbench.Cap.StateMachine.can_submit?(message, latest)
  def can_review?(message, latest), do: CapWorkbench.Cap.StateMachine.can_review?(message, latest)

  def can_publish?(message, latest),
    do: CapWorkbench.Cap.StateMachine.can_publish?(message, latest)

  def can_derive?(message), do: CapWorkbench.Cap.StateMachine.can_derive?(message)

  defdelegate enum_options(kind), to: Index
  defdelegate workflow_label(state), to: Index
  defdelegate workflow_badge(state), to: Index

  def review_state_label(:pending), do: "待复核"
  def review_state_label(:in_review), do: "复核中"
  def review_state_label(:approved), do: "已通过"
  def review_state_label(:rejected), do: "已退回"

  def field_label(:headline), do: "标题"
  def field_label(:description), do: "描述"
  def field_label(:instruction), do: "处置建议"
  def field_label(:event), do: "事件"
  def field_label(:category), do: "类别"
  def field_label(:urgency), do: "紧急度"
  def field_label(:severity), do: "严重度"
  def field_label(:certainty), do: "确定性"
  def field_label(:language), do: "语言"
  def field_label(:area_description), do: "区域描述"
  def field_label(:geocodes), do: "地区编码"
  def field_label(other), do: to_string(other)

  def render_value(value) when is_list(value), do: Enum.join(value, ", ")
  def render_value(nil), do: ""
  def render_value(value), do: to_string(value)

  defp error_text(:stale), do: "版本冲突：内容已被他人修改，已为你重新载入，请重试。"
  defp error_text(:stale_review), do: "复核结论已失效，请针对最新版本重新复核。"
  defp error_text(:already_published), do: "该消息已发布，不能重复发布。"
  defp error_text(:duplicate_publish), do: "重复发布已被拦截。"
  defp error_text(:not_publishable), do: "仅通过复核的最新版本可发布。"
  defp error_text(:not_latest_version), do: "存在更新的草稿版本，操作已取消。"
  defp error_text(:not_submittable), do: "当前状态无法提交复核。"
  defp error_text(:not_editable), do: "该消息已冻结，无法编辑。"
  defp error_text(:not_published), do: "仅已发布的消息可创建更正或解除。"
  defp error_text({:illegal_transition, _s, _e}), do: "非法的状态流转。"
  defp error_text(other), do: "操作失败：#{inspect(other)}"

  @doc false
  def enums, do: Enums
  @doc false
  def draft_version, do: DraftVersion
end
