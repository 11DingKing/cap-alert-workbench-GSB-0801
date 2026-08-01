defmodule CapAlertWorkbenchWeb.AlertNewLive do
  use CapAlertWorkbenchWeb, :live_view

  alias CapAlertWorkbench.CapAlert
  alias CapAlertWorkbench.CapAlert.{Enums, Geocode}

  @impl true
  def mount(_params, _session, socket) do
    changeset = build_changeset(%{})
    {:ok, assign(socket, page_title: "新建预警", form: to_form(changeset))}
  end

  @impl true
  def handle_event("add_geocode", _params, socket) do
    params = socket.assigns.form.params
    geocodes = params["geocodes"] || %{}

    next_index =
      geocodes |> Map.keys() |> Enum.map(&String.to_integer/1) |> Enum.max(fn -> -1 end)

    geocodes =
      Map.put(geocodes, Integer.to_string(next_index + 1), %{
        "value_name" => "Same",
        "value" => ""
      })

    params = Map.put(params, "geocodes", geocodes)

    {:noreply, assign(socket, :form, to_form(build_changeset(params)))}
  end

  def handle_event("remove_geocode", %{"index" => index}, socket) do
    params = socket.assigns.form.params
    geocodes = Map.delete(params["geocodes"] || %{}, index)
    params = Map.put(params, "geocodes", geocodes)

    {:noreply, assign(socket, :form, to_form(build_changeset(params)))}
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
    CapAlert.AlertVersion.changeset(
      %CapAlert.AlertVersion{
        geocodes: [
          %Geocode{value_name: "Same", value: "440800"},
          %Geocode{value_name: "Same", value: "440900"}
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
            <.input field={@form[:language]} label="语言 (language)" />
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
            <.input
              field={@form[:urgency]}
              type="select"
              label="紧急度 urgency"
              options={select_opts(Enums.cap_urgencies(), &Enums.cap_urgency_string/1)}
            />
            <.input
              field={@form[:severity]}
              type="select"
              label="严重度 severity"
              options={select_opts(Enums.cap_severities(), &Enums.cap_severity_string/1)}
            />
            <.input
              field={@form[:certainty]}
              type="select"
              label="确定性 certainty"
              options={select_opts(Enums.cap_certainties(), &Enums.cap_certainty_string/1)}
            />
          </div>
        </section>

        <section class="rounded-xl border border-slate-200 bg-white p-5 shadow-sm">
          <h2 class="mb-4 text-sm font-semibold text-slate-900">内容</h2>
          <div class="space-y-4">
            <.input field={@form[:event]} label="事件 event" required />
            <.input field={@form[:headline]} label="标题 headline" />
            <.input field={@form[:description]} type="textarea" label="描述 description" rows="3" />
            <.input
              field={@form[:instruction]}
              type="textarea"
              label="处置建议 instruction"
              rows="3"
            />
          </div>
        </section>

        <section class="rounded-xl border border-slate-200 bg-white p-5 shadow-sm">
          <div class="mb-4 flex items-center justify-between">
            <h2 class="text-sm font-semibold text-slate-900">区域编码 geocodes</h2>
            <button type="button" phx-click="add_geocode" class="btn btn-ghost btn-sm">
              <.icon name="hero-plus" class="size-4" /> 添加区域
            </button>
          </div>

          <div class="space-y-2">
            <.inputs_for :let={g} field={@form[:geocodes]}>
              <div class="flex gap-2">
                <.input field={g[:value_name]} class="w-32" placeholder="valueName" />
                <.input field={g[:value]} class="flex-1" placeholder="区域编码" />
                <button
                  type="button"
                  phx-click="remove_geocode"
                  phx-value-index={g.index}
                  class="btn btn-ghost btn-sm text-red-600 self-start mt-6"
                >
                  <.icon name="hero-trash" class="size-4" />
                </button>
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
