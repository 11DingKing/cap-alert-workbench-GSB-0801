defmodule CapAlertWorkbenchWeb.VersionDiffLive do
  use CapAlertWorkbenchWeb, :live_view

  alias CapAlertWorkbench.CapAlert
  alias CapAlertWorkbenchWeb.CapAlertUI

  @impl true
  def mount(%{"identifier" => identifier, "left" => left, "right" => right}, _session, socket) do
    CapAlert.subscribe_alert(identifier)
    versions = CapAlert.list_versions(identifier)
    left_v = find_version(versions, left)
    right_v = find_version(versions, right)

    diff =
      case {left_v, right_v} do
        {%{} = l, %{} = r} -> CapAlert.diff_versions(l, r)
        _ -> []
      end

    socket =
      socket
      |> assign(:identifier, identifier)
      |> assign(:versions, versions)
      |> assign(:left, left_v)
      |> assign(:right, right_v)
      |> assign(:diff, diff)
      |> assign(:page_title, "版本差异")

    {:ok, socket}
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
    left_v = find_version(versions, left)
    right_v = find_version(versions, right)
    diff = if left_v && right_v, do: CapAlert.diff_versions(left_v, right_v), else: []

    {:noreply,
     socket
     |> assign(:left, left_v)
     |> assign(:right, right_v)
     |> assign(:diff, diff)}
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
        <h1 class="mb-4 text-lg font-semibold text-slate-900">版本差异对比</h1>

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

        <div :if={@left && @right} class="overflow-hidden rounded-lg border border-slate-200">
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
                :for={change <- @diff}
                class={if(change.changed, do: "bg-amber-50/60", else: "")}
              >
                <td class="px-4 py-2 font-medium text-slate-700">
                  {change.label}
                  <span
                    :if={change.changed}
                    class="ml-2 inline-block rounded bg-amber-200 px-1.5 text-[10px] text-amber-900"
                  >已变更</span>
                </td>
                <td class="px-4 py-2 text-slate-600">{change.old || "—"}</td>
                <td class="px-4 py-2 text-slate-900">{change.new || "—"}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
