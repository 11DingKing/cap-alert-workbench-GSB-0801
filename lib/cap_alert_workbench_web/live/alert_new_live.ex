defmodule CapAlertWorkbenchWeb.AlertNewLive do
  use CapAlertWorkbenchWeb, :live_view

  alias CapAlertWorkbench.CapAlert
  alias CapAlertWorkbench.CapAlert.{AlertInfo, AlertVersion, Enums, Geocode}

  @impl true
  def mount(_params, _session, socket) do
    changeset = build_changeset(%{})
    {:ok, assign(socket, page_title: "新建预警", form: to_form(changeset))}
  end

  @impl true
  def handle_event("add_info", _params, socket) do
    params = socket.assigns.form.params
    infos = params["infos"] || %{}

    next_index =
      infos |> Map.keys() |> Enum.map(&String.to_integer/1) |> Enum.max(fn -> -1 end)

    new_info = %{
      "language" => "zh-CN",
      "event" => "",
      "headline" => "",
      "description" => "",
      "instruction" => "",
      "urgency" => "immediate",
      "severity" => "severe",
      "certainty" => "likely",
      "area_desc" => "",
      "geocodes" => %{"0" => %{"value_name" => "Same", "value" => ""}}
    }

    infos = Map.put(infos, Integer.to_string(next_index + 1), new_info)
    params = Map.put(params, "infos", infos)

    {:noreply,
     assign(socket, :form, to_form(build_changeset(params) |> Map.put(:action, :insert)))}
  end

  def handle_event("remove_info", %{"index" => index}, socket) do
    params = socket.assigns.form.params
    infos = Map.delete(params["infos"] || %{}, index)
    params = Map.put(params, "infos", infos)

    {:noreply,
     assign(socket, :form, to_form(build_changeset(params) |> Map.put(:action, :insert)))}
  end

  def handle_event("add_geocode", %{"info-index" => info_index}, socket) do
    params = socket.assigns.form.params
    infos = params["infos"] || %{}
    info = infos[info_index] || %{}
    geocodes = info["geocodes"] || %{}

    next_index =
      geocodes |> Map.keys() |> Enum.map(&String.to_integer/1) |> Enum.max(fn -> -1 end)

    geocodes =
      Map.put(geocodes, Integer.to_string(next_index + 1), %{
        "value_name" => "Same",
        "value" => ""
      })

    infos = Map.put(infos, info_index, Map.put(info, "geocodes", geocodes))
    params = Map.put(params, "infos", infos)

    {:noreply,
     assign(socket, :form, to_form(build_changeset(params) |> Map.put(:action, :insert)))}
  end

  def handle_event("remove_geocode", %{"info-index" => info_index, "index" => index}, socket) do
    params = socket.assigns.form.params
    infos = params["infos"] || %{}
    info = infos[info_index] || %{}
    geocodes = Map.delete(info["geocodes"] || %{}, index)
    infos = Map.put(infos, info_index, Map.put(info, "geocodes", geocodes))
    params = Map.put(params, "infos", infos)

    {:noreply,
     assign(socket, :form, to_form(build_changeset(params) |> Map.put(:action, :insert)))}
  end

  def handle_event("validate", %{"alert_version" => params}, socket) do
    changeset = build_changeset(params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"alert_version" => params}, socket) do
    sender = params["sender"] || "duty-officer@gd.example"

    attrs =
      params
      |> Map.drop(["alert_identifier"])
      |> Map.put("sender", sender)

    case CapAlert.create_alert(
           Map.merge(attrs, %{"identifier" => params["alert_identifier"], "sender" => sender}),
           "duty-officer"
         ) do
      {:ok, %{alert: alert}} ->
        {:noreply,
         socket
         |> put_flash(:info, "预警草稿已创建")
         |> push_navigate(to: ~p"/alerts/#{alert.identifier}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}

      {:error, other} ->
        {:noreply, put_flash(socket, :error, "创建失败：#{inspect(other)}")}
    end
  end

  defp build_changeset(params) do
    AlertVersion.changeset(
      %AlertVersion{
        infos: [
          %AlertInfo{
            language: "zh-CN",
            event: "暴雨",
            urgency: :immediate,
            severity: :severe,
            certainty: :likely,
            geocodes: [
              %Geocode{value_name: "Same", value: "440800"},
              %Geocode{value_name: "Same", value: "440900"}
            ]
          }
        ],
        sent: DateTime.utc_now()
      },
      params
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={%{}}>
      <div class="mb-4 flex items-center gap-2 text-sm text-slate-500">
        <.link navigate={~p"/"} class="hover:text-slate-700">预警列表</.link>
        <span>/</span>
        <span class="text-slate-700">新建预警</span>
      </div>

      <.form for={@form} id="new-alert-form" phx-change="validate" phx-submit="save" class="space-y-6">
        <section class="rounded-xl border border-slate-200 bg-white p-5 shadow-sm">
          <h2 class="mb-4 text-sm font-semibold text-slate-900">标识与发送</h2>
          <div class="grid gap-4 sm:grid-cols-2">
            <.input field={@form[:alert_identifier]} label="消息标识 (identifier)" required />
            <.input field={@form[:sender]} label="发送方 (sender)" required />
            <.input field={@form[:sent]} type="datetime-local" label="发送时间 (sent)" required />
          </div>
        </section>

        <section class="rounded-xl border border-slate-200 bg-white p-5 shadow-sm">
          <h2 class="mb-4 text-sm font-semibold text-slate-900">CAP 分类</h2>
          <div class="grid gap-4 sm:grid-cols-3">
            <.input
              field={@form[:status]}
              type="select"
              label="状态 status"
              options={select_opts(Enums.cap_statuses(), &Enums.cap_status_string/1)}
            />
            <.input
              field={@form[:msg_type]}
              type="select"
              label="类型 msgType"
              options={select_opts(Enums.cap_msg_types(), &Enums.cap_msg_type_string/1)}
            />
            <.input
              field={@form[:scope]}
              type="select"
              label="范围 scope"
              options={select_opts(Enums.cap_scopes(), &Enums.cap_scope_string/1)}
            />
          </div>
        </section>

        <section class="rounded-xl border border-slate-200 bg-white p-5 shadow-sm">
          <div class="mb-4 flex items-center justify-between">
            <h2 class="text-sm font-semibold text-slate-900">Info 段（按地区/语言）</h2>
            <button type="button" phx-click="add_info" class="btn btn-ghost btn-sm">
              <.icon name="hero-plus" class="size-4" /> 添加 Info
            </button>
          </div>

          <div class="space-y-4">
            <.inputs_for :let={info_f} field={@form[:infos]}>
              <div class="rounded-lg border border-slate-200 bg-slate-50/60 p-4">
                <div class="mb-3 flex items-center justify-between">
                  <span class="text-xs font-medium uppercase tracking-wide text-slate-500">
                    Info #{info_f.index}
                  </span>
                  <button
                    type="button"
                    phx-click="remove_info"
                    phx-value-index={info_f.index}
                    class="btn btn-ghost btn-xs text-red-600"
                  >
                    <.icon name="hero-trash" class="size-4" /> 删除
                  </button>
                </div>

                <div class="grid gap-3 sm:grid-cols-2">
                  <.input field={info_f[:event]} label="事件 event" required />
                  <.input field={info_f[:headline]} label="标题 headline" />
                  <.input field={info_f[:language]} label="语言 language" />
                  <.input field={info_f[:area_desc]} label="区域描述 areaDesc" />
                  <.input
                    field={info_f[:urgency]}
                    type="select"
                    label="紧急度 urgency"
                    options={select_opts(Enums.cap_urgencies(), &Enums.cap_urgency_string/1)}
                  />
                  <.input
                    field={info_f[:severity]}
                    type="select"
                    label="严重度 severity"
                    options={select_opts(Enums.cap_severities(), &Enums.cap_severity_string/1)}
                  />
                  <.input
                    field={info_f[:certainty]}
                    type="select"
                    label="确定性 certainty"
                    options={select_opts(Enums.cap_certainties(), &Enums.cap_certainty_string/1)}
                  />
                </div>

                <.input
                  field={info_f[:description]}
                  type="textarea"
                  label="描述 description"
                  rows="2"
                />
                <.input
                  field={info_f[:instruction]}
                  type="textarea"
                  label="处置建议 instruction"
                  rows="2"
                />

                <div class="mt-3">
                  <div class="mb-2 flex items-center justify-between">
                    <span class="text-xs font-medium text-slate-600">区域编码 geocodes</span>
                    <button
                      type="button"
                      phx-click="add_geocode"
                      phx-value-info-index={info_f.index}
                      class="btn btn-ghost btn-xs"
                    >
                      <.icon name="hero-plus" class="size-4" /> 添加区域
                    </button>
                  </div>
                  <div class="space-y-2">
                    <.inputs_for :let={g} field={info_f[:geocodes]}>
                      <div class="flex gap-2">
                        <.input field={g[:value_name]} class="w-32" placeholder="valueName" />
                        <.input field={g[:value]} class="flex-1" placeholder="区域编码" />
                        <button
                          type="button"
                          phx-click="remove_geocode"
                          phx-value-info-index={info_f.index}
                          phx-value-index={g.index}
                          class="btn btn-ghost btn-sm text-red-600 self-end"
                        >
                          <.icon name="hero-trash" class="size-4" />
                        </button>
                      </div>
                    </.inputs_for>
                  </div>
                </div>
              </div>
            </.inputs_for>
          </div>
        </section>

        <div class="flex justify-end gap-2">
          <.link navigate={~p"/"} class="btn btn-ghost">取消</.link>
          <button type="submit" class="btn btn-primary">创建草稿</button>
        </div>
      </.form>
    </Layouts.app>
    """
  end

  defp select_opts(atoms, label_fun) do
    Enum.map(atoms, fn a -> {label_fun.(a), Atom.to_string(a)} end)
  end
end
