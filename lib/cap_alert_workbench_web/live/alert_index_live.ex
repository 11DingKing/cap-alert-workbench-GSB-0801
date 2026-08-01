defmodule CapAlertWorkbenchWeb.AlertIndexLive do
  use CapAlertWorkbenchWeb, :live_view

  alias CapAlertWorkbench.CapAlert
  alias CapAlertWorkbenchWeb.CapAlertUI

  @impl true
  def mount(_params, _session, socket) do
    CapAlert.subscribe_alerts()
    {:ok, assign(socket, page_title: "预警列表") |> reload()}
  end

  @impl true
  def handle_info({:alert_created, _alert}, socket), do: {:noreply, reload(socket)}
  def handle_info({:alert_changed, _identifier}, socket), do: {:noreply, reload(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp reload(socket) do
    rows = CapAlert.list_alerts_with_latest()
    assign(socket, rows: rows, rows_empty?: rows == [])
  end

  attr :state, :atom, required: true

  defp state_badge(assigns) do
    {text, class} = CapAlertUI.workflow_badge(assigns.state)
    assigns = assign(assigns, text: text, class: class)

    ~H"""
    <span class={@class}>{@text}</span>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={%{}}>
      <div class="mb-6 flex items-center justify-between">
        <div>
          <h1 class="text-xl font-semibold text-slate-900">公共预警编审工作台</h1>
          <p class="text-sm text-slate-500">
            草稿编辑、版本差异、复核与发布流程 · 发布后仅可更正或解除
          </p>
        </div>
        <.link navigate={~p"/alerts/new"} class="btn btn-primary">
          <.icon name="hero-plus" class="size-4" /> 新建预警
        </.link>
      </div>

      <div class="space-y-3">
        <.link
          :for={{alert, latest} <- @rows}
          navigate={~p"/alerts/#{alert.identifier}"}
          class="block rounded-xl border border-slate-200 bg-white p-4 shadow-sm transition hover:border-red-300 hover:shadow-md"
        >
          <div class="flex items-start justify-between gap-4">
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-2">
                <span class="font-mono text-sm font-semibold text-slate-900">
                  {alert.identifier}
                </span>
                <.state_badge :if={latest} state={latest.workflow_state} />
                <span :if={latest} class="text-xs text-slate-400">
                  v{latest.version_number}
                </span>
              </div>
              <p class="mt-1 truncate text-sm text-slate-500">{alert.sender}</p>
            </div>
            <div class="shrink-0 text-right text-xs text-slate-400">
              更新于 {CapAlertUI.format_sent(alert.updated_at)}
            </div>
          </div>
        </.link>

        <div
          :if={@rows_empty?}
          class="rounded-xl border border-dashed border-slate-300 bg-white p-10 text-center"
        >
          <.icon name="hero-bell-alert" class="mx-auto size-10 text-slate-300" />
          <p class="mt-3 text-sm text-slate-500">暂无预警，点击右上角“新建预警”开始。</p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
