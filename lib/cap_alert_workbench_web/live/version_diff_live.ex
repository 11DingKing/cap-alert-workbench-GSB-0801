defmodule CapAlertWorkbenchWeb.VersionDiffLive do
  use CapAlertWorkbenchWeb, :live_view

  alias CapAlertWorkbench.CapAlert
  alias CapAlertWorkbenchWeb.CapAlertUI

  @impl true
  def mount(%{"identifier" => identifier, "left" => left, "right" => right}, _session, socket) do
    CapAlert.subscribe_alert(identifier)
    versions = CapAlert.list_versions(identifier)
    socket = assign_diff(socket, identifier, versions, left, right)
    {:ok, assign(socket, :identifier, identifier) |> assign(:versions, versions)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("compare", %{"left" => left, "right" => right}, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/alerts/#{socket.assigns.identifier}/diff/#{left}/#{right}"
     )}
  end

  @impl true
  def handle_params(%{"left" => left, "right" => right}, _uri, socket) do
    versions = CapAlert.list_versions(socket.assigns.identifier)
    {:noreply, assign_diff(socket, socket.assigns.identifier, versions, left, right)}
  end

  defp assign_diff(socket, _identifier, versions, left, right) do
    left_v = find_version(versions, left)
    right_v = find_version(versions, right)

    diff =
      if left_v && right_v do
        CapAlert.diff_versions(left_v, right_v)
      else
        %{alert_changes: [], regions: []}
      end

    socket
    |> assign(:left, left_v)
    |> assign(:right, right_v)
    |> assign(:diff, diff)
    |> assign(:page_title, "版本差异")
  end

  defp find_version(versions, number) do
    n = if is_binary(number), do: String.to_integer(number), else: number
    Enum.find(versions, &(&1.version_number == n))
  end

  defp version_options(versions) do
    versions
    |> Enum.map(fn v ->
      {"v#{v.version_number} · #{CapAlertUI.format_sent(v.inserted_at)}", v.version_number}
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={%{}}>
      <div class="mb-4 flex items-center gap-2 text-sm text-slate-500">
        <.link navigate={~p"/alerts/#{@identifier}"} class="hover:text-slate-700">返回工作台</.link>
        <span>/</span>
        <span class="text-slate-700">版本差异</span>
      </div>

      <section class="rounded-xl border border-slate-200 bg-white p-5 shadow-sm">
        <h1 class="mb-4 text-lg font-semibold text-slate-900">版本差异对比（按地区）</h1>

        <form id="diff-form" phx-change="compare" class="mb-6 flex flex-wrap items-end gap-4">
          <div>
            <label class="mb-1 block text-xs text-slate-500">旧版本</label>
            <select name="left" class="select">
              {Phoenix.HTML.Form.options_for_select(
                version_options(@versions),
                @left && @left.version_number
              )}
            </select>
          </div>
          <span class="pb-2 text-slate-400">→</span>
          <div>
            <label class="mb-1 block text-xs text-slate-500">新版本</label>
            <select name="right" class="select">
              {Phoenix.HTML.Form.options_for_select(
                version_options(@versions),
                @right && @right.version_number
              )}
            </select>
          </div>
        </form>

        <div :if={@left && @right} class="space-y-6">
          <div
            :if={Enum.any?(@diff.alert_changes, & &1.changed)}
            class="overflow-hidden rounded-lg border border-slate-200"
          >
            <h2 class="border-b border-slate-200 bg-slate-50 px-4 py-2 text-sm font-semibold text-slate-700">
              预警级字段
            </h2>
            <table class="w-full text-sm">
              <thead class="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
                <tr>
                  <th class="px-4 py-2">字段</th>
                  <th class="px-4 py-2">v{@left.version_number}</th>
                  <th class="px-4 py-2">v{@right.version_number}</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-slate-100">
                <tr
                  :for={change <- Enum.filter(@diff.alert_changes, & &1.changed)}
                  class="bg-amber-50/60"
                >
                  <td class="px-4 py-2 font-medium text-slate-700">{change.label}</td>
                  <td class="px-4 py-2 text-slate-500">{change.old || "—"}</td>
                  <td class="px-4 py-2 text-slate-900">{change.new || "—"}</td>
                </tr>
              </tbody>
            </table>
          </div>

          <div>
            <h2 class="mb-3 text-sm font-semibold text-slate-700">按地区差异</h2>
            <div class="space-y-3">
              <.region_diff
                :for={region <- @diff.regions}
                region={region}
                left_v={@left}
                right_v={@right}
              />
            </div>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :region, :map
  attr :left_v, :any
  attr :right_v, :any

  defp region_diff(assigns) do
    ~H"""
    <div class={[
      "overflow-hidden rounded-lg border",
      region_border(@region.status)
    ]}>
      <div class="flex flex-wrap items-center justify-between gap-2 border-b px-4 py-2 text-sm">
        <div class="flex items-center gap-2">
          <span class="font-medium text-slate-800">{@region.label}</span>
          <.region_status_badge status={@region.status} />
        </div>
      </div>

      <div :if={@region.status in [:added, :removed]} class="px-4 py-3 text-sm">
        <p class="text-xs uppercase tracking-wide text-slate-400">
          {if @region.status == :added, do: "新增地区", else: "移除地区"}
        </p>
        <.info_summary info={
          if @region.status == :added, do: @region.new_info, else: @region.old_info
        } />
      </div>

      <table :if={@region.status in [:changed, :unchanged]} class="w-full text-sm">
        <thead class="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
          <tr>
            <th class="px-4 py-2">字段</th>
            <th class="px-4 py-2">v{@left_v.version_number}</th>
            <th class="px-4 py-2">v{@right_v.version_number}</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-slate-100">
          <tr
            :for={change <- @region.changes}
            class={if(change.changed, do: "bg-amber-50/60", else: "")}
          >
            <td class="px-4 py-2 font-medium text-slate-700">
              {change.label}
              <span
                :if={change.changed}
                class="ml-2 inline-block rounded bg-amber-200 px-1.5 text-[10px] text-amber-900"
              >已变更</span>
            </td>
            <td class="px-4 py-2 text-slate-500">{change.old || "—"}</td>
            <td class="px-4 py-2 text-slate-900">{change.new || "—"}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :info, :any

  defp info_summary(assigns) do
    ~H"""
    <div :if={@info} class="mt-1 grid gap-1 sm:grid-cols-2">
      <p><span class="text-slate-400">事件：</span>{@info.event || "—"}</p>
      <p><span class="text-slate-400">标题：</span>{@info.headline || "—"}</p>
      <p><span class="text-slate-400">严重度：</span>{@info.severity || "—"}</p>
      <p><span class="text-slate-400">紧急度：</span>{@info.urgency || "—"}</p>
    </div>
    """
  end

  defp region_border(:added), do: "border-emerald-300 bg-emerald-50/30"
  defp region_border(:removed), do: "border-rose-300 bg-rose-50/30"
  defp region_border(:changed), do: "border-amber-300"
  defp region_border(:unchanged), do: "border-slate-200"

  attr :status, :atom, required: true

  defp region_status_badge(assigns) do
    ~H"""
    <span class={["rounded px-2 py-0.5 text-xs font-medium", badge_class(@status)]}>
      {badge_text(@status)}
    </span>
    """
  end

  defp badge_class(:added), do: "bg-emerald-100 text-emerald-800"
  defp badge_class(:removed), do: "bg-rose-100 text-rose-800"
  defp badge_class(:changed), do: "bg-amber-100 text-amber-800"
  defp badge_class(:unchanged), do: "bg-slate-100 text-slate-600"

  defp badge_text(:added), do: "新增"
  defp badge_text(:removed), do: "移除"
  defp badge_text(:changed), do: "已变更"
  defp badge_text(:unchanged), do: "未变更"
end
