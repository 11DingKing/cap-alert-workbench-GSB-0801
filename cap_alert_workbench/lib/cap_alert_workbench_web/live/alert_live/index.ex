defmodule CapAlertWorkbenchWeb.AlertLive.Index do
  use CapAlertWorkbenchWeb, :live_view

  alias CapAlertWorkbench.Cap

  @impl true
  def mount(_params, _session, socket) do
    Cap.subscribe_all()
    alerts = Cap.list_alerts()

    {:ok,
     socket
     |> assign(:alerts_empty?, alerts == [])
     |> stream(:alerts, alerts)}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, assign(socket, :page_title, "CAP 预警编审工作台")}
  end

  @impl true
  def handle_event("seed_initial", _params, socket) do
    message = Cap.Xml.Codec.seed_message()

    attrs =
      message
      |> Map.from_struct()
      |> Map.put(:actor, "system")
      |> Map.to_list()

    case Cap.create_alert(attrs) do
      {:ok, _} ->
        alerts = Cap.list_alerts()

        {:noreply,
         socket
         |> put_flash(:info, "已创建初始预警 #{message.identifier}")
         |> assign(:alerts_empty?, alerts == [])
         |> stream(:alerts, alerts, reset: true)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "创建失败: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info({event, alert}, socket) when event in [:alert_created] do
    {:noreply, stream_insert(socket, :alerts, alert)}
  end

  def handle_info({_event, alert}, socket) do
    {:noreply, stream_insert(socket, :alerts, alert)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={%{}}>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold tracking-tight">CAP 预警编审工作台</h1>
            <p class="text-sm text-base-content/70 mt-1">
              结构化公共预警的草稿、复核、发布与更正解除流程
            </p>
          </div>
          <.button phx-click="seed_initial" variant="primary">
            <.icon name="hero-plus" class="size-4" /> 新建初始暴雨预警
          </.button>
        </div>

        <div class="card bg-base-100 shadow-sm border border-base-200">
          <div class="card-body p-0">
            <div class="overflow-x-auto">
              <table class="table table-zebra">
                <thead>
                  <tr>
                    <th>标识</th>
                    <th>发送方</th>
                    <th>状态</th>
                    <th>最新发布版本</th>
                    <th>锁版本/修订</th>
                    <th>最近活动</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody id="alerts" phx-update="stream">
                  <tr :for={{id, alert} <- @streams.alerts} id={id}>
                    <td class="font-mono text-xs">{alert.identifier}</td>
                    <td>{alert.sender}</td>
                    <td><.status_badge status={alert.status} /></td>
                    <td>{alert.latest_published_version || "—"}</td>
                    <td class="font-mono text-xs">
                      v{alert.draft_lock_version} / r{alert.draft_revision}
                    </td>
                    <td class="text-xs text-base-content/60">
                      {format_time(alert.last_activity_at)}
                    </td>
                    <td>
                      <.link navigate={~p"/alerts/#{alert.id}"} class="btn btn-sm btn-ghost">
                        打开 <span aria-hidden="true">&rarr;</span>
                      </.link>
                    </td>
                  </tr>
                  <tr :if={@alerts_empty?}>
                    <td colspan="7" class="text-center text-base-content/50 py-8">
                      暂无预警，点击右上角新建初始暴雨预警
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp status_badge(%{status: status} = assigns) do
    class =
      case status do
        :draft -> "badge-ghost"
        :in_review -> "badge-warning"
        :approved -> "badge-info"
        :published -> "badge-success"
        :canceled -> "badge-error"
        _ -> "badge-ghost"
      end

    assigns = assign(assigns, :class, class)

    ~H"""
    <span class={["badge", @class]}>{label(@status)}</span>
    """
  end

  defp label(:draft), do: "草稿"
  defp label(:in_review), do: "待复核"
  defp label(:approved), do: "已通过"
  defp label(:published), do: "已发布"
  defp label(:canceled), do: "已解除"
  defp label(other), do: to_string(other)

  defp format_time(nil), do: "—"

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end
end
