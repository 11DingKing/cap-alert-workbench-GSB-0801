defmodule CapAlertWorkbenchWeb.ReviewLive do
  use CapAlertWorkbenchWeb, :live_view

  alias CapAlertWorkbench.CapAlert
  alias CapAlertWorkbench.CapAlert.Enums
  alias CapAlertWorkbenchWeb.CapAlertUI

  @impl true
  def mount(%{"identifier" => identifier, "version_id" => version_id}, session, socket) do
    CapAlert.subscribe_alert(identifier)
    actor = session["actor"] || "复核员"
    version = CapAlert.get_version!(version_id)

    socket =
      socket
      |> assign(:actor, actor)
      |> assign(:identifier, identifier)
      |> assign(:version, version)
      |> assign(:alert, CapAlert.get_alert!(identifier))
      |> assign(:comment, "")
      |> assign(:page_title, "复核 v#{version.version_number}")

    {:ok, socket}
  end

  @impl true
  def handle_info({:version_updated, version}, socket)
      when version.id == socket.assigns.version.id do
    {:noreply,
     socket
     |> assign(:version, CapAlert.get_version!(version.id))}
  end

  def handle_info({:version_published, version}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "v#{version.version_number} 已发布")
     |> push_navigate(to: ~p"/alerts/#{socket.assigns.identifier}")}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("set_comment", %{"comment" => comment}, socket) do
    {:noreply, assign(socket, :comment, comment)}
  end

  def handle_event("approve", _, socket) do
    do_review(socket, :approve)
  end

  def handle_event("reject", _, socket) do
    do_review(socket, :reject)
  end

  defp do_review(socket, decision) do
    case CapAlert.review(
           socket.assigns.version,
           decision,
           socket.assigns.comment,
           socket.assigns.actor
         ) do
      {:ok, updated} ->
        msg = if decision == :approve, do: "复核通过，可发布", else: "已退回修改"

        {:noreply,
         socket
         |> put_flash(:info, msg)
         |> push_navigate(to: ~p"/alerts/#{socket.assigns.identifier}")
         |> then(fn s -> assign(s, :version, updated) end)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, review_error(reason))}
    end
  end

  defp review_error(:stale_review), do: "该版本已不是最新草稿，复核结论已过期（存在更新的草稿）"
  defp review_error(:not_latest), do: "该版本已不是最新版本，无法复核"
  defp review_error(reason), do: "复核失败：#{inspect(reason)}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={%{}}>
      <div class="mb-4 flex items-center gap-2 text-sm text-slate-500">
        <.link navigate={~p"/alerts/#{@identifier}"} class="hover:text-slate-700">返回工作台</.link>
        <span>/</span>
        <span class="text-slate-700">复核 v{@version.version_number}</span>
      </div>

      <div class="grid gap-6 lg:grid-cols-3">
        <div class="lg:col-span-2 space-y-6">
          <section class="rounded-xl border border-slate-200 bg-white p-5 shadow-sm">
            <div class="mb-4 flex items-center justify-between">
              <h1 class="text-lg font-semibold text-slate-900">
                复核 v{@version.version_number} · {Enums.cap_msg_type_string(@version.msg_type)}
              </h1>
              {state_badge(@version.workflow_state)}
            </div>

            <div class="grid gap-4 sm:grid-cols-2 text-sm">
              <.field label="消息标识" value={@version.alert_identifier} />
              <.field label="发送方" value={@version.sender} />
              <.field label="发送时间" value={CapAlertUI.format_sent(@version.sent)} />
              <.field
                label="CAP 状态/类型"
                value={"#{Enums.cap_status_string(@version.status)} / #{Enums.cap_msg_type_string(@version.msg_type)}"}
              />
              <.field label="范围" value={Enums.cap_scope_string(@version.scope)} />
            </div>

            <div :if={@version.references} class="mt-3">
              <p class="mb-1 text-xs font-medium uppercase text-slate-400">引用</p>
              <p class="break-all font-mono text-xs text-slate-500">{@version.references}</p>
            </div>

            <div class="mt-5 space-y-3">
              <div
                :for={{info, idx} <- Enum.with_index(@version.infos)}
                class="rounded-lg border border-slate-200 bg-slate-50/60 p-3"
              >
                <div class="mb-2 flex flex-wrap items-center gap-2">
                  <span class="text-xs font-semibold uppercase text-slate-500">Info #{idx}</span>
                  {severity_badge(info.severity)}
                  <span class="text-xs text-slate-400">{CapAlertUI.geocodes_summary(info.geocodes)}</span>
                </div>
                <div class="grid gap-2 sm:grid-cols-2 text-sm">
                  <.field label="事件" value={info.event} />
                  <.field label="标题" value={info.headline} />
                  <.field
                    label="紧急度"
                    value={info.urgency && Enums.cap_urgency_string(info.urgency)}
                  />
                  <.field
                    label="确定性"
                    value={info.certainty && Enums.cap_certainty_string(info.certainty)}
                  />
                </div>
                <div class="mt-2 text-sm">
                  <p class="text-xs uppercase tracking-wide text-slate-400">描述</p>
                  <p class="whitespace-pre-wrap text-slate-600">{info.description || "—"}</p>
                </div>
                <div class="mt-1 text-sm">
                  <p class="text-xs uppercase tracking-wide text-slate-400">处置建议</p>
                  <p class="whitespace-pre-wrap text-slate-600">{info.instruction || "—"}</p>
                </div>
              </div>
            </div>
          </section>

          <section class="rounded-xl border border-slate-200 bg-white p-5 shadow-sm">
            <h2 class="mb-3 text-sm font-semibold text-slate-900">复核意见</h2>
            <form phx-submit="approve" class="space-y-3">
              <textarea
                name="comment"
                value={@comment}
                phx-input="set_comment"
                rows="3"
                class="w-full textarea"
                placeholder="请输入复核意见（通过或退回时均可填写）"
              ></textarea>
              <div class="flex justify-end gap-2">
                <button
                  type="button"
                  phx-click="reject"
                  class="btn bg-rose-600 text-white hover:bg-rose-700"
                >
                  <.icon name="hero-x-circle" class="size-4" /> 退回修改
                </button>
                <button type="submit" class="btn bg-emerald-600 text-white hover:bg-emerald-700">
                  <.icon name="hero-check-circle" class="size-4" /> 复核通过
                </button>
              </div>
            </form>
          </section>
        </div>

        <aside class="space-y-6">
          <section class="rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-800">
            <p class="font-medium">并发保护</p>
            <p class="mt-1 text-amber-700">
              如果在您复核期间作者已基于此版本创建了更新的草稿，提交时将被拒绝，以避免旧的复核结论覆盖新草稿。
            </p>
          </section>
        </aside>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string
  attr :value, :any

  defp field(assigns) do
    ~H"""
    <div>
      <p class="text-xs uppercase tracking-wide text-slate-400">{@label}</p>
      <p class="mt-0.5 text-sm text-slate-700">{@value || "—"}</p>
    </div>
    """
  end

  defp state_badge(state) do
    {text, class} = CapAlertUI.workflow_badge(state)
    assigns = %{text: text, class: class}

    ~H"""
    <span class={@class}>{@text}</span>
    """
  end

  defp severity_badge(severity) do
    {text, class} = CapAlertUI.cap_severity_badge(severity)
    assigns = %{text: text, class: class}

    ~H"""
    <span class={@class}>{@text}</span>
    """
  end
end
