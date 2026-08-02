defmodule CapAlertWorkbenchWeb.AlertLive do
  use CapAlertWorkbenchWeb, :live_view

  alias CapAlertWorkbench.CapAlert
  alias CapAlertWorkbench.CapAlert.{AlertVersion, Enums, StateMachine}
  alias CapAlertWorkbenchWeb.CapAlertUI

  @impl true
  def mount(%{"identifier" => identifier}, session, socket) do
    CapAlert.subscribe_alert(identifier)
    actor = session["actor"] || "值班员"

    socket =
      socket
      |> assign(:actor, actor)
      |> assign(:identifier, identifier)
      |> assign(:xml_preview, false)
      |> assign(:conflict, false)
      |> reload_data()

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  defp reload_data(socket) do
    case CapAlert.load_alert(socket.assigns.identifier) do
      nil ->
        socket
        |> put_flash(:error, "预警不存在")
        |> push_navigate(to: ~p"/")

      data ->
        latest = data.latest_version
        editable = latest && StateMachine.editable?(latest.workflow_state)

        socket
        |> assign(:data, data)
        |> assign(:latest, latest)
        |> assign(:published, data.published_version)
        |> assign(:versions, data.versions)
        |> assign(:audit_events, data.audit_events)
        |> assign(:outbox, data.outbox)
        |> assign(:editable?, editable)
        |> maybe_build_form()
    end
  end

  defp maybe_build_form(%{assigns: %{editable?: true, latest: latest}} = socket) do
    if socket.assigns[:form] && socket.assigns[:editing_version_id] == latest.id &&
         not socket.assigns[:conflict] do
      socket
    else
      changeset = AlertVersion.changeset(latest, %{})
      assign(socket, form: to_form(changeset), editing_version_id: latest.id)
    end
  end

  defp maybe_build_form(socket), do: assign(socket, :form, nil)

  # ---------------------------------------------------------------------------
  # PubSub
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:version_updated, version}, socket) do
    {:noreply, handle_remote_change(version, socket)}
  end

  def handle_info({:version_created, version}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "已创建新版本 v#{version.version_number}")
     |> reload_data()}
  end

  def handle_info({:version_published, version}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "v#{version.version_number} 已发布")
     |> assign(:conflict, false)
     |> reload_data()}
  end

  def handle_info({:alert_created, _alert}, socket), do: {:noreply, reload_data(socket)}
  def handle_info({:outbox_event, _type, _payload}, socket), do: {:noreply, reload_data(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp handle_remote_change(version, socket) do
    conflict? =
      socket.assigns[:editing_version_id] == version.id and
        socket.assigns[:form] != nil and
        form_lock_version(socket.assigns.form) != version.lock_version

    socket
    |> assign(:conflict, conflict?)
    |> reload_data_preserving_form()
  end

  defp reload_data_preserving_form(socket) do
    data = CapAlert.load_alert(socket.assigns.identifier)
    latest = data.latest_version

    socket
    |> assign(:data, data)
    |> assign(:latest, latest)
    |> assign(:published, data.published_version)
    |> assign(:versions, data.versions)
    |> assign(:audit_events, data.audit_events)
    |> assign(:outbox, data.outbox)
    |> assign(:editable?, latest && StateMachine.editable?(latest.workflow_state))
  end

  defp form_lock_version(form) do
    case form.params["lock_version"] do
      nil -> form.data.lock_version
      "" -> form.data.lock_version
      v when is_binary(v) -> String.to_integer(v)
      v -> v
    end
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("validate", %{"alert_version" => params}, socket) do
    changeset =
      socket.assigns.latest
      |> AlertVersion.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("add_info", _params, socket) do
    params = ensure_infos_params(socket)
    infos = params["infos"]

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

    {:noreply, rebuild_form(socket, params)}
  end

  def handle_event("remove_info", %{"index" => index}, socket) do
    params = ensure_infos_params(socket)
    infos = Map.delete(params["infos"], index)
    params = Map.put(params, "infos", infos)
    {:noreply, rebuild_form(socket, params)}
  end

  def handle_event("add_geocode", %{"info-index" => info_index}, socket) do
    params = ensure_infos_params(socket)
    infos = params["infos"]
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
    {:noreply, rebuild_form(socket, params)}
  end

  def handle_event("remove_geocode", %{"info-index" => info_index, "index" => index}, socket) do
    params = ensure_infos_params(socket)
    infos = params["infos"]
    info = infos[info_index] || %{}
    geocodes = Map.delete(info["geocodes"] || %{}, index)
    infos = Map.put(infos, info_index, Map.put(info, "geocodes", geocodes))
    params = Map.put(params, "infos", infos)
    {:noreply, rebuild_form(socket, params)}
  end

  def handle_event("save", %{"alert_version" => params}, socket) do
    version = socket.assigns.latest

    case CapAlert.edit_draft(version, params, socket.assigns.actor) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> assign(:conflict, false)
         |> assign(:form, nil)
         |> put_flash(:info, "草稿已保存")
         |> reload_data()}

      {:error, :stale} ->
        {:noreply,
         socket
         |> assign(:conflict, true)
         |> put_flash(:error, "乐观锁冲突：该草稿已被他人修改，请刷新后重试")
         |> reload_data_preserving_form()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}

      {:error, other} ->
        {:noreply, put_flash(socket, :error, "保存失败：#{inspect(other)}")}
    end
  end

  def handle_event("reload", _, socket) do
    {:noreply, socket |> assign(:conflict, false) |> reload_data()}
  end

  def handle_event("submit", _, socket) do
    handle_command(
      socket,
      fn -> CapAlert.submit_for_review(socket.assigns.latest, socket.assigns.actor) end,
      "已提交复核"
    )
  end

  def handle_event("withdraw", _, socket) do
    handle_command(
      socket,
      fn -> CapAlert.withdraw_from_review(socket.assigns.latest, socket.assigns.actor) end,
      "已撤回到草稿"
    )
  end

  def handle_event("revise", _, socket) do
    handle_command(
      socket,
      fn -> CapAlert.revise(socket.assigns.latest, socket.assigns.actor) end,
      "已基于当前版本创建新草稿"
    )
  end

  def handle_event("publish", _, socket) do
    handle_command(
      socket,
      fn -> CapAlert.publish(socket.assigns.latest, socket.assigns.actor) end,
      "发布成功"
    )
  end

  def handle_event("create_correction", _, socket) do
    attrs = %{"alert_identifier" => socket.assigns.identifier}

    handle_command(
      socket,
      fn -> CapAlert.create_correction(attrs, socket.assigns.actor) end,
      "已创建更正草稿（Update），请编辑后提交复核"
    )
  end

  def handle_event("create_c1", _, socket) do
    attrs = %{"source_identifier" => socket.assigns.identifier}

    case CapAlert.create_correction_alert(attrs, socket.assigns.actor) do
      {:ok, %{alert: alert}} ->
        {:noreply,
         socket
         |> put_flash(:info, "已创建更正 C1（440900→Extreme），请编辑后提交复核")
         |> push_navigate(to: ~p"/alerts/#{alert.identifier}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, format_changeset_errors(changeset))
         |> reload_data_preserving_form()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("create_cancellation", _, socket) do
    [first_info | _] = socket.assigns.latest.infos

    attrs = %{
      "alert_identifier" => socket.assigns.identifier,
      "infos" => %{
        "0" => %{
          "event" => first_info.event,
          "headline" => "预警解除",
          "description" => "该预警已解除。",
          "instruction" => "本次预警事件已结束。",
          "severity" => first_info.severity && Atom.to_string(first_info.severity),
          "urgency" => first_info.urgency && Atom.to_string(first_info.urgency),
          "certainty" => first_info.certainty && Atom.to_string(first_info.certainty),
          "geocodes" =>
            Enum.with_index(first_info.geocodes)
            |> Map.new(fn {gc, i} ->
              {Integer.to_string(i), %{"value_name" => gc.value_name, "value" => gc.value}}
            end)
        }
      }
    }

    handle_command(
      socket,
      fn -> CapAlert.create_cancellation(attrs, socket.assigns.actor) end,
      "已创建解除草稿（Cancel），请编辑后提交复核"
    )
  end

  def handle_event("toggle_xml", _, socket) do
    {:noreply, assign(socket, :xml_preview, not socket.assigns.xml_preview)}
  end

  defp ensure_infos_params(socket) do
    params = socket.assigns.form.params

    if params["infos"] do
      params
    else
      Map.put(params, "infos", infos_to_form_params(socket.assigns.latest.infos))
    end
  end

  defp infos_to_form_params(infos) do
    infos
    |> Enum.with_index()
    |> Map.new(fn {info, idx} ->
      geocodes =
        info.geocodes
        |> Enum.with_index()
        |> Map.new(fn {gc, gidx} ->
          {Integer.to_string(gidx),
           %{"value_name" => gc.value_name || "Same", "value" => gc.value || ""}}
        end)

      {Integer.to_string(idx),
       %{
         "language" => info.language || "zh-CN",
         "event" => info.event || "",
         "headline" => info.headline || "",
         "description" => info.description || "",
         "instruction" => info.instruction || "",
         "urgency" => info.urgency && Atom.to_string(info.urgency),
         "severity" => info.severity && Atom.to_string(info.severity),
         "certainty" => info.certainty && Atom.to_string(info.certainty),
         "area_desc" => info.area_desc || "",
         "geocodes" => geocodes
       }}
    end)
  end

  defp rebuild_form(socket, params) do
    changeset =
      socket.assigns.latest
      |> AlertVersion.changeset(params)
      |> Map.put(:action, :validate)

    assign(socket, :form, to_form(changeset))
  end

  defp handle_command(socket, fun, success_msg) do
    case fun.() do
      {:ok, _result} ->
        {:noreply,
         socket
         |> assign(:conflict, false)
         |> put_flash(:info, success_msg)
         |> reload_data()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, format_changeset_errors(changeset))
         |> reload_data_preserving_form()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  defp error_message(:stale), do: "乐观锁冲突：版本已被他人修改"
  defp error_message(:not_editable), do: "当前状态不可编辑"
  defp error_message(:not_latest), do: "该版本已不是最新版本，操作被拒绝"
  defp error_message(:stale_review), do: "复核结论已过期：已存在更新的草稿，请刷新"
  defp error_message(:not_publishable), do: "只有通过复核的最新版本可以发布"
  defp error_message(:no_published_version), do: "尚未发布过任何版本，无法更正/解除"
  defp error_message(reason), do: "操作失败：#{inspect(reason)}"

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map(fn {k, v} -> "#{k}: #{Enum.join(v, ", ")}" end)
    |> Enum.join("; ")
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={%{}}>
      <div class="mb-4 flex flex-wrap items-center justify-between gap-2">
        <div class="flex items-center gap-2 text-sm text-slate-500">
          <.link navigate={~p"/"} class="hover:text-slate-700">预警列表</.link>
          <span>/</span>
          <span class="font-mono text-slate-700">{@identifier}</span>
        </div>
        <div class="flex items-center gap-2">
          <span class="text-xs text-slate-400">当前操作员：<span class="text-slate-600">{@actor}</span></span>
        </div>
      </div>

      <div
        :if={@conflict}
        class="mb-4 flex items-start gap-2 rounded-lg border border-amber-300 bg-amber-50 p-3 text-sm text-amber-800"
      >
        <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0" />
        <div>
          <p class="font-medium">乐观锁冲突：草稿已被他人修改</p>
          <p class="mt-0.5 text-amber-700">
            您正在编辑的版本已过期。请复制未保存的内容，然后刷新页面以加载最新版本，再重新编辑。
          </p>
          <button
            type="button"
            phx-click="reload"
            class="mt-2 rounded bg-amber-600 px-2 py-1 text-xs font-medium text-white hover:bg-amber-700"
          >
            刷新到最新版本
          </button>
        </div>
      </div>

      <div class="grid gap-6 lg:grid-cols-3">
        <div class="space-y-6 lg:col-span-2">
          <.header_section latest={@latest} published={@published} data={@data} />

          <.edit_section
            :if={@editable? and @form != nil}
            form={@form}
            latest={@latest}
            xml_preview={@xml_preview}
          />

          <.readonly_section
            :if={@latest != nil and not @editable?}
            latest={@latest}
            xml_preview={@xml_preview}
          />

          <.actions_section latest={@latest} published={@published} identifier={@identifier} />
        </div>

        <div class="space-y-6">
          <.versions_sidebar versions={@versions} latest={@latest} identifier={@identifier} />
          <.audit_sidebar audit_events={@audit_events} />
          <.outbox_sidebar outbox={@outbox} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :latest, :any
  attr :published, :any
  attr :data, :any

  defp header_section(assigns) do
    ~H"""
    <section class="rounded-xl border border-slate-200 bg-white p-5 shadow-sm">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div>
          <div class="flex flex-wrap items-center gap-2">
            <h1 class="font-mono text-lg font-semibold text-slate-900">
              {@data.alert.identifier}
            </h1>
            {state_badge(@latest && @latest.workflow_state)}
            {severity_badge(CapAlertUI.highest_severity(@latest && @latest.infos))}
          </div>
          <p class="mt-1 text-sm text-slate-500">
            {@data.alert.sender} · 发送于 {CapAlertUI.format_sent(@latest && @latest.sent)}
          </p>
          <p :if={@latest} class="mt-1 text-xs text-slate-400">
            {CapAlertUI.infos_summary(@latest.infos)}
          </p>
        </div>
        <div class="text-right text-xs text-slate-400">
          <p>最新版本 v{@latest && @latest.version_number}</p>
          <p :if={@published}>已发布 v{@published.version_number}</p>
        </div>
      </div>
    </section>
    """
  end

  attr :form, :any
  attr :latest, :any
  attr :xml_preview, :boolean

  defp edit_section(assigns) do
    ~H"""
    <section class="rounded-xl border border-slate-200 bg-white p-5 shadow-sm">
      <.form
        for={@form}
        id="draft-form"
        phx-change="validate"
        phx-submit="save"
        class="space-y-4"
      >
        <.input field={@form[:lock_version]} type="hidden" />

        <div class="grid gap-4 sm:grid-cols-2">
          <.input field={@form[:sender]} label="发送方 sender" required />
          <.input field={@form[:sent]} type="datetime-local" label="发送时间 sent" required />
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

        <div class="flex items-center justify-between border-t border-slate-100 pt-4">
          <h3 class="text-sm font-semibold text-slate-900">Info 段（按地区/语言）</h3>
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

        <div class="flex items-center justify-between border-t border-slate-100 pt-4">
          <button type="button" phx-click="toggle_xml" class="btn btn-ghost btn-sm">
            {(@xml_preview && "隐藏") || "预览"} CAP XML
          </button>
          <div class="flex gap-2">
            <button type="submit" class="btn btn-primary">
              <.icon name="hero-bookmark" class="size-4" /> 保存草稿
            </button>
          </div>
        </div>

        <div :if={@xml_preview} class="rounded-lg bg-slate-900 p-4">
          <pre class="max-h-96 overflow-auto text-xs text-emerald-300" phx-no-curly-interpolation><%= CapAlert.export_cap(@latest) %></pre>
        </div>
      </.form>
    </section>
    """
  end

  attr :latest, :any
  attr :xml_preview, :boolean

  defp readonly_section(assigns) do
    ~H"""
    <section class="rounded-xl border border-slate-200 bg-white p-5 shadow-sm">
      <div class="grid gap-4 sm:grid-cols-2 text-sm">
        <.readonly_field label="发送方" value={@latest.sender} />
        <.readonly_field label="发送时间" value={CapAlertUI.format_sent(@latest.sent)} />
        <.readonly_field
          label="状态/类型"
          value={"#{Enums.cap_status_string(@latest.status)} / #{Enums.cap_msg_type_string(@latest.msg_type)}"}
        />
        <.readonly_field
          label="范围"
          value={Enums.cap_scope_string(@latest.scope)}
        />
      </div>

      <div class="mt-4 space-y-3">
        <div
          :for={{info, idx} <- Enum.with_index(@latest.infos)}
          class="rounded-lg border border-slate-200 bg-slate-50/60 p-3"
        >
          <div class="mb-2 flex flex-wrap items-center gap-2">
            <span class="text-xs font-semibold uppercase text-slate-500">Info #{idx}</span>
            {severity_badge(info.severity)}
            <span class="text-xs text-slate-400">{CapAlertUI.geocodes_summary(info.geocodes)}</span>
          </div>
          <div class="grid gap-2 sm:grid-cols-2 text-sm">
            <.readonly_field label="事件" value={info.event} />
            <.readonly_field label="标题" value={info.headline} />
            <.readonly_field
              label="紧急度"
              value={info.urgency && Enums.cap_urgency_string(info.urgency)}
            />
            <.readonly_field
              label="确定性"
              value={info.certainty && Enums.cap_certainty_string(info.certainty)}
            />
            <.readonly_field label="区域描述" value={info.area_desc} />
            <.readonly_field label="语言" value={info.language} />
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

      <div :if={@latest.references} class="mt-3">
        <p class="mb-1 text-xs font-medium uppercase text-slate-400">引用 references</p>
        <p class="break-all font-mono text-xs text-slate-500">{@latest.references}</p>
      </div>
      <div :if={@latest.review_comment} class="mt-3">
        <p class="mb-1 text-xs font-medium uppercase text-slate-400">复核意见</p>
        <p class="text-sm text-slate-600">{@latest.review_comment} — {@latest.reviewed_by}</p>
      </div>

      <div class="mt-4 flex items-center justify-between border-t border-slate-100 pt-4">
        <button type="button" phx-click="toggle_xml" class="btn btn-ghost btn-sm">
          {(@xml_preview && "隐藏") || "查看"} CAP XML
        </button>
      </div>
      <div :if={@xml_preview} class="mt-3 rounded-lg bg-slate-900 p-4">
        <pre class="max-h-96 overflow-auto text-xs text-emerald-300" phx-no-curly-interpolation><%= CapAlert.export_cap(@latest) %></pre>
      </div>
    </section>
    """
  end

  attr :latest, :any
  attr :published, :any
  attr :identifier, :string

  defp actions_section(assigns) do
    ~H"""
    <section class="rounded-xl border border-slate-200 bg-white p-5 shadow-sm">
      <h2 class="mb-3 text-sm font-semibold text-slate-900">操作</h2>
      <div class="flex flex-wrap gap-2">
        <button
          :if={@latest && @latest.workflow_state in [:draft, :changes_requested]}
          type="button"
          phx-click="submit"
          class="btn btn-primary btn-sm"
        >
          <.icon name="hero-paper-airplane" class="size-4" /> 提交复核
        </button>

        <.link
          :if={@latest && @latest.workflow_state == :in_review}
          navigate={~p"/alerts/#{@latest.alert_identifier}/review/#{@latest.id}"}
          class="btn btn-primary btn-sm"
        >
          <.icon name="hero-check-badge" class="size-4" /> 前往复核
        </.link>

        <button
          :if={@latest && @latest.workflow_state == :in_review}
          type="button"
          phx-click="withdraw"
          class="btn btn-ghost btn-sm"
        >
          <.icon name="hero-arrow-uturn-left" class="size-4" /> 撤回修改
        </button>

        <button
          :if={@latest && @latest.workflow_state == :in_review}
          type="button"
          phx-click="revise"
          class="btn btn-ghost btn-sm text-amber-700"
        >
          <.icon name="hero-pencil-square" class="size-4" /> 基于此版本新建草稿
        </button>

        <button
          :if={@latest && @latest.workflow_state == :approved}
          type="button"
          phx-click="publish"
          class="btn btn-success btn-sm bg-emerald-600 text-white hover:bg-emerald-700"
        >
          <.icon name="hero-megaphone" class="size-4" /> 发布
        </button>

        <button
          :if={
            @published && @published.workflow_state == :published &&
              @latest.workflow_state in [:published, :superseded, :cancelled]
          }
          type="button"
          phx-click="create_c1"
          class="btn btn-warning btn-sm bg-amber-500 text-white hover:bg-amber-600"
        >
          <.icon name="hero-pencil" class="size-4" /> 创建更正 C1（440900→Extreme）
        </button>

        <button
          :if={
            @published && @published.workflow_state == :published &&
              @latest.workflow_state in [:published, :superseded, :cancelled]
          }
          type="button"
          phx-click="create_correction"
          class="btn btn-ghost btn-sm"
        >
          <.icon name="hero-pencil-square" class="size-4" /> 同标识更正 (Update)
        </button>

        <button
          :if={
            @published && @published.workflow_state == :published &&
              @latest.workflow_state in [:published, :superseded]
          }
          type="button"
          phx-click="create_cancellation"
          class="btn btn-error btn-sm bg-rose-600 text-white hover:bg-rose-700"
        >
          <.icon name="hero-x-circle" class="size-4" /> 创建解除 (Cancel)
        </button>
      </div>
    </section>
    """
  end

  attr :versions, :list
  attr :latest, :any
  attr :identifier, :string

  defp versions_sidebar(assigns) do
    ~H"""
    <section class="rounded-xl border border-slate-200 bg-white p-4 shadow-sm">
      <h2 class="mb-3 text-sm font-semibold text-slate-900">版本历史</h2>
      <ul class="space-y-2">
        <li :for={v <- Enum.reverse(@versions)} class="rounded-lg border border-slate-100 p-2 text-sm">
          <div class="flex items-center justify-between">
            <.link
              navigate={version_link(@identifier, v, @latest)}
              class="font-medium text-slate-800 hover:text-red-600"
            >
              v{v.version_number} · {Enums.cap_msg_type_string(v.msg_type)}
            </.link>
            {state_badge(v.workflow_state)}
          </div>
          <p class="mt-0.5 text-xs text-slate-400">{CapAlertUI.format_sent(v.inserted_at)}</p>
        </li>
      </ul>
    </section>
    """
  end

  attr :audit_events, :list

  defp audit_sidebar(assigns) do
    ~H"""
    <section class="rounded-xl border border-slate-200 bg-white p-4 shadow-sm">
      <h2 class="mb-3 text-sm font-semibold text-slate-900">审计事件</h2>
      <ul class="space-y-2 text-sm">
        <li :for={e <- @audit_events} class="border-b border-slate-50 pb-2 last:border-0">
          <div class="flex items-center justify-between">
            <span class="font-medium text-slate-700">{e.action}</span>
            <span class="text-xs text-slate-400">{CapAlertUI.format_sent(e.inserted_at)}</span>
          </div>
          <p class="text-xs text-slate-500">{e.actor} · version #{e.version_id || "—"}</p>
        </li>
        <li :if={@audit_events == []} class="text-xs text-slate-400">暂无审计记录</li>
      </ul>
    </section>
    """
  end

  attr :outbox, :list

  defp outbox_sidebar(assigns) do
    ~H"""
    <section class="rounded-xl border border-slate-200 bg-white p-4 shadow-sm">
      <h2 class="mb-3 text-sm font-semibold text-slate-900">通知 Outbox</h2>
      <ul class="space-y-2 text-sm">
        <li :for={o <- @outbox} class="flex items-center justify-between">
          <div>
            <p class="font-mono text-xs text-slate-700">{o.event_type}</p>
            <p class="text-xs text-slate-400">{CapAlertUI.format_sent(o.inserted_at)}</p>
          </div>
          {outbox_badge(o.status)}
        </li>
        <li :if={@outbox == []} class="text-xs text-slate-400">暂无通知</li>
      </ul>
    </section>
    """
  end

  attr :label, :string
  attr :value, :any

  defp readonly_field(assigns) do
    ~H"""
    <div>
      <p class="text-xs uppercase tracking-wide text-slate-400">{@label}</p>
      <p class="mt-0.5 text-sm text-slate-700">{@value || "—"}</p>
    </div>
    """
  end

  defp state_badge(nil), do: ""

  defp state_badge(state) do
    {text, class} = CapAlertUI.workflow_badge(state)
    assigns = %{text: text, class: class}

    ~H"""
    <span class={@class}>{@text}</span>
    """
  end

  defp severity_badge(nil), do: ""

  defp severity_badge(severity) do
    {text, class} = CapAlertUI.cap_severity_badge(severity)
    assigns = %{text: text, class: class}

    ~H"""
    <span class={@class}>{@text}</span>
    """
  end

  defp outbox_badge(status) do
    {text, class} = CapAlertUI.outbox_badge(status)
    assigns = %{text: text, class: class}

    ~H"""
    <span class={[
      "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium ring-1 ring-inset",
      @class
    ]}>{@text}</span>
    """
  end

  defp select_opts(atoms, label_fun) do
    Enum.map(atoms, fn a -> {label_fun.(a), Atom.to_string(a)} end)
  end

  defp version_link(identifier, v, latest) do
    if latest && v.id != latest.id && latest.version_number > 1 do
      ~p"/alerts/#{identifier}/diff/#{v.version_number}/#{latest.version_number}"
    else
      ~p"/alerts/#{identifier}"
    end
  end
end
