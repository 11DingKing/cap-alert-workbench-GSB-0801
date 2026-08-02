defmodule CapAlertWorkbenchWeb.AlertLive.Show do
  use CapAlertWorkbenchWeb, :live_view

  alias CapAlertWorkbench.Cap
  alias CapAlertWorkbench.Cap.{AreaCodes, Enums, VersionDiff}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    Cap.subscribe(id)

    case Cap.fetch_alert(id) do
      {:ok, alert} ->
        versions = Cap.list_versions(id)
        audits = Cap.list_audit_events(id)

        {:ok,
         socket
         |> assign(:alert, alert)
         |> assign(:versions, versions)
         |> assign(:audits, audits)
         |> assign(:page_title, alert.identifier)
         |> assign(:tab, "draft")
         |> assign(:diff_selection, %{a: nil, b: nil})
         |> assign(:diff_result, nil)
         |> assign(:review_comment, "")
         |> assign(:correction_note, "")
         |> assign(:xml_preview, nil)
         |> assign_form()
         |> assign_followup_forms()
         |> assign_review_form()}

      {:error, :not_found} ->
        {:ok, socket |> put_flash(:error, "预警不存在") |> redirect(to: ~p"/")}
    end
  end

  @impl true
  def handle_params(%{"a" => a, "b" => b}, _url, socket) do
    {a_num, _} = Integer.parse(a)
    {b_num, _} = Integer.parse(b)

    case Cap.diff_versions(socket.assigns.alert.id, a_num, b_num) do
      {:ok, diff} ->
        {:noreply,
         socket
         |> assign(:tab, "versions")
         |> assign(:diff_selection, %{a: a_num, b: b_num})
         |> assign(:diff_result, VersionDiff.changed_fields(diff))}

      _ ->
        {:noreply, assign(socket, :tab, "versions")}
    end
  end

  def handle_params(_params, _url, socket), do: {:noreply, socket}

  defp assign_form(socket) do
    payload = socket.assigns.alert.draft_payload || %{}

    form_data = %{
      "event" => payload["event"],
      "headline" => payload["headline"],
      "description" => payload["description"],
      "instruction" => payload["instruction"],
      "urgency" => payload["urgency"],
      "severity" => payload["severity"],
      "certainty" => payload["certainty"],
      "scope" => payload["scope"],
      "area_codes" => payload["area_codes"] || [],
      "note" => payload["note"],
      "expected_lock_version" => socket.assigns.alert.draft_lock_version
    }

    assign(socket, :form, to_form(form_data, as: :draft))
  end

  defp assign_followup_forms(socket) do
    payload = socket.assigns.alert.draft_payload || %{}

    correction = %{
      "headline" => payload["headline"],
      "description" => payload["description"],
      "instruction" => payload["instruction"],
      "note" => ""
    }

    cancellation = %{"note" => ""}

    socket
    |> assign(:correction_form, to_form(correction, as: :correction))
    |> assign(:cancellation_form, to_form(cancellation, as: :cancellation))
  end

  defp assign_review_form(socket) do
    assign(socket, :review_form, to_form(%{"comment" => ""}, as: :review))
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply,
     socket
     |> assign(:tab, tab)
     |> maybe_load_xml_preview(tab)}
  end

  def handle_event("validate", %{"draft" => params}, socket) do
    form = to_form(params, as: :draft)
    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("save_draft", %{"draft" => params}, socket) do
    expected = parse_int(params["expected_lock_version"])
    actor = current_actor(socket)

    update_params = %{
      "event" => params["event"],
      "headline" => params["headline"],
      "description" => params["description"],
      "instruction" => params["instruction"],
      "urgency" => params["urgency"],
      "severity" => params["severity"],
      "certainty" => params["certainty"],
      "scope" => params["scope"],
      "note" => params["note"],
      "area_codes" => params["area_codes"] || []
    }

    case Cap.update_draft(socket.assigns.alert.id, expected, update_params, actor) do
      {:ok, %{alert: alert}} ->
        {:noreply,
         socket
         |> put_flash(:info, "草稿已保存（锁版本已递增，旧复核自动失效）")
         |> assign(:alert, alert)
         |> assign(:versions, Cap.list_versions(alert.id))
         |> assign(:audits, Cap.list_audit_events(alert.id))
         |> assign_form()}

      {:error, {:lock_version_mismatch, current, expected}} ->
        {:noreply,
         socket
         |> put_flash(:error, "乐观锁冲突：当前锁版本为 #{current}，您提交的是 #{expected}，请刷新后重试")
         |> assign(:alert, Cap.get_alert!(socket.assigns.alert.id))
         |> assign_form()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "保存失败: #{inspect(reason)}")}
    end
  end

  def handle_event("submit_for_review", _params, socket) do
    case Cap.submit_for_review(socket.assigns.alert.id, current_actor(socket)) do
      {:ok, %{alert: alert}} ->
        {:noreply,
         socket
         |> put_flash(:info, "已提交复核")
         |> reload(alert)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "提交失败: #{inspect(reason)}")}
    end
  end

  def handle_event("review_decision", %{"decision" => decision} = params, socket) do
    actor = current_actor(socket)

    review_params = %{
      "decision" => decision,
      "comment" => params["comment"] || ""
    }

    case Cap.decide_review(socket.assigns.alert.id, review_params, actor) do
      {:ok, %{alert: alert}} ->
        {:noreply,
         socket
         |> put_flash(:info, "复核结论已记录：#{decision_label(decision)}")
         |> reload(alert)}

      {:error, {:stale_review, _old, _new}} ->
        {:noreply,
         socket
         |> put_flash(:error, "该复核已过期：草稿在复核期间被修改，旧结论不能用于发布")
         |> reload(Cap.get_alert!(socket.assigns.alert.id))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "复核失败: #{inspect(reason)}")}
    end
  end

  def handle_event("publish", _params, socket) do
    case Cap.publish(socket.assigns.alert.id, current_actor(socket)) do
      {:ok, %{alert: alert}} ->
        {:noreply,
         socket
         |> put_flash(:info, "预警已发布，内容不可再修改")
         |> reload(alert)}

      {:error, :already_published} ->
        {:noreply, put_flash(socket, :error, "该预警已发布，不能重复发布")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "发布失败: #{inspect(reason)}")}
    end
  end

  def handle_event("create_correction", %{"correction" => params}, socket) do
    case Cap.create_correction(
           socket.assigns.alert.id,
           %{
             "headline" => params["headline"],
             "description" => params["description"],
             "instruction" => params["instruction"],
             "note" => params["note"]
           },
           current_actor(socket)
         ) do
      {:ok, %{alert: alert}} ->
        {:noreply,
         socket
         |> put_flash(:info, "更正版本已发布")
         |> reload(alert)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "更正失败: #{inspect(reason)}")}
    end
  end

  def handle_event("create_cancellation", %{"cancellation" => params}, socket) do
    case Cap.create_cancellation(
           socket.assigns.alert.id,
           %{"note" => params["note"]},
           current_actor(socket)
         ) do
      {:ok, %{alert: alert}} ->
        {:noreply,
         socket
         |> put_flash(:info, "解除消息已发布")
         |> reload(alert)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "解除失败: #{inspect(reason)}")}
    end
  end

  def handle_event("preview_xml", _params, socket) do
    xml = Cap.export_xml(socket.assigns.alert)
    {:noreply, assign(socket, :xml_preview, xml)}
  end

  def handle_event("close_xml", _params, socket) do
    {:noreply, assign(socket, :xml_preview, nil)}
  end

  def handle_event("compute_diff", %{"a" => a, "b" => b}, socket) do
    {a_num, _} = Integer.parse(a)
    {b_num, _} = Integer.parse(b)

    case Cap.diff_versions(socket.assigns.alert.id, a_num, b_num) do
      {:ok, diff} ->
        {:noreply,
         socket
         |> assign(:diff_selection, %{a: a_num, b: b_num})
         |> assign(:diff_result, VersionDiff.changed_fields(diff))}

      _ ->
        {:noreply, put_flash(socket, :error, "无法生成差异")}
    end
  end

  @impl true
  def handle_info({event, %Cap.Alert{} = alert}, socket) when event != :notification do
    if alert.id == socket.assigns.alert.id do
      {:noreply,
       socket
       |> assign(:alert, alert)
       |> assign(:versions, Cap.list_versions(alert.id))
       |> assign(:audits, Cap.list_audit_events(alert.id))}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp reload(socket, alert) do
    socket
    |> assign(:alert, alert)
    |> assign(:versions, Cap.list_versions(alert.id))
    |> assign(:audits, Cap.list_audit_events(alert.id))
    |> assign_form()
    |> assign_followup_forms()
    |> assign_review_form()
  end

  defp maybe_load_xml_preview(socket, "xml") do
    xml = Cap.export_xml(socket.assigns.alert)
    assign(socket, :xml_preview, xml)
  end

  defp maybe_load_xml_preview(socket, _), do: assign(socket, :xml_preview, nil)

  defp current_actor(_socket), do: "duty-officer"

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil
  defp parse_int(s) when is_binary(s), do: String.to_integer(s)
  defp parse_int(i) when is_integer(i), do: i

  defp decision_label("approved"), do: "通过"
  defp decision_label("changes_requested"), do: "需修改"
  defp decision_label("rejected"), do: "驳回"

  defp status_label(:draft), do: "草稿"
  defp status_label(:in_review), do: "待复核"
  defp status_label(:approved), do: "已通过"
  defp status_label(:published), do: "已发布"
  defp status_label(:canceled), do: "已解除"
  defp status_label(other), do: to_string(other)

  defp version_kind_label(:draft), do: "草稿快照"
  defp version_kind_label(:correction), do: "更正"
  defp version_kind_label(:cancellation), do: "解除"

  defp area_options do
    Enum.map(AreaCodes.all(), fn {code, desc} -> {"#{code} #{desc}", code} end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={%{}}>
      <div class="space-y-6">
        <div class="flex items-start justify-between gap-4">
          <div>
            <.link navigate={~p"/alerts"} class="text-sm link link-hover">
              &larr; 返回列表
            </.link>
            <h1 class="text-2xl font-bold tracking-tight mt-2 font-mono">{@alert.identifier}</h1>
            <div class="flex items-center gap-2 mt-2">
              <span class={["badge", badge_class(@alert.status)]}>{status_label(@alert.status)}</span>
              <span class="text-xs text-base-content/60">
                发送方 {@alert.sender} · 锁版本 v{@alert.draft_lock_version} · 修订 r{@alert.draft_revision}
              </span>
            </div>
          </div>
          <div class="flex gap-2">
            <.button phx-click="preview_xml" class="btn-sm btn-outline">查看 CAP XML</.button>
          </div>
        </div>

        <div role="tablist" class="tabs tabs-boxed">
          {tab_button(assigns, "draft", "草稿编辑")}
          {tab_button(assigns, "versions", "版本与差异")}
          {tab_button(assigns, "review", "复核")}
          {tab_button(assigns, "publish", "发布")}
          {tab_button(assigns, "followup", "更正/解除")}
          {tab_button(assigns, "audit", "审计与通知")}
        </div>

        <div :if={@xml_preview} class="card bg-base-100 border border-base-200">
          <div class="card-body">
            <div class="flex justify-between items-center">
              <h3 class="font-semibold">CAP XML 预览</h3>
              <button phx-click="close_xml" class="btn btn-sm btn-ghost">关闭</button>
            </div>
            <pre
              class={["bg-base-200 rounded p-4 text-xs overflow-auto max-h-96"]}
              phx-no-curly-interpolation
            ><code>{@xml_preview}</code></pre>
          </div>
        </div>

        <.draft_tab :if={@tab == "draft"} alert={@alert} form={@form} />
        <.versions_tab
          :if={@tab == "versions"}
          versions={@versions}
          diff_result={@diff_result}
          diff_selection={@diff_selection}
          alert_id={@alert.id}
        />
        <.review_tab :if={@tab == "review"} alert={@alert} versions={@versions} />
        <.publish_tab :if={@tab == "publish"} alert={@alert} versions={@versions} />
        <.followup_tab :if={@tab == "followup"} alert={@alert} />
        <.audit_tab :if={@tab == "audit"} audits={@audits} versions={@versions} />
      </div>
    </Layouts.app>
    """
  end

  defp tab_button(assigns, tab_id, label) do
    active = assigns.tab == tab_id

    assigns =
      assigns
      |> assign(:tab_id, tab_id)
      |> assign(:label, label)
      |> assign(:active, active)

    ~H"""
    <button
      role="tab"
      phx-click="switch_tab"
      phx-value-tab={@tab_id}
      class={["tab", @active && "tab-active"]}
      aria-selected={to_string(@active)}
    >
      {@label}
    </button>
    """
  end

  defp badge_class(:draft), do: "badge-ghost"
  defp badge_class(:in_review), do: "badge-warning"
  defp badge_class(:approved), do: "badge-info"
  defp badge_class(:published), do: "badge-success"
  defp badge_class(:canceled), do: "badge-error"
  defp badge_class(_), do: "badge-ghost"

  defp draft_tab(assigns) do
    ~H"""
    <.form
      for={@form}
      id="draft-form"
      phx-change="validate"
      phx-submit="save_draft"
      class="card bg-base-100 border border-base-200"
    >
      <div class="card-body space-y-4">
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <.input field={@form[:event]} label="事件类型" />
          <.input field={@form[:headline]} label="标题" />
        </div>
        <.input field={@form[:description]} type="textarea" label="描述" rows="4" />
        <.input field={@form[:instruction]} type="textarea" label="处置建议" rows="3" />
        <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
          <.input
            field={@form[:urgency]}
            type="select"
            label="紧急度"
            options={enum_options(Enums.urgencies())}
          />
          <.input
            field={@form[:severity]}
            type="select"
            label="严重度"
            options={enum_options(Enums.severities())}
          />
          <.input
            field={@form[:certainty]}
            type="select"
            label="确定性"
            options={enum_options(Enums.certainties())}
          />
          <.input
            field={@form[:scope]}
            type="select"
            label="范围"
            options={enum_options(Enums.scopes())}
          />
        </div>
        <.input
          field={@form[:area_codes]}
          type="select"
          label="影响区域"
          multiple={true}
          options={area_options()}
          class="h-32"
        />
        <.input field={@form[:note]} type="textarea" label="备注" rows="2" />
        <input type="hidden" name="draft[expected_lock_version]" value={@alert.draft_lock_version} />
        <div class="flex justify-between items-center">
          <span class="text-xs text-base-content/60">
            乐观锁：保存时若锁版本已被其他浏览器修改将被拒绝
          </span>
          <button type="submit" class="btn btn-primary">保存草稿（递增锁版本）</button>
        </div>
      </div>
    </.form>
    """
  end

  defp versions_tab(assigns) do
    ~H"""
    <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
      <div class="card bg-base-100 border border-base-200">
        <div class="card-body">
          <h3 class="font-semibold mb-2">不可变版本历史</h3>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>#</th><th>类型</th><th>状态</th><th>修订种子</th><th>发布时间</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={v <- @versions}>
                  <td class="font-mono">{v.version_number}</td>
                  <td>{version_kind_label(v.kind)}</td>
                  <td>
                    <span class={["badge badge-sm", badge_class(v.status)]}>{status_label(v.status)}</span>
                  </td>
                  <td class="font-mono text-xs">r{v.revision_seed}</td>
                  <td class="text-xs">
                    {v.published_at && Calendar.strftime(v.published_at, "%Y-%m-%d %H:%M:%S")}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <div class="card bg-base-100 border border-base-200">
        <div class="card-body">
          <h3 class="font-semibold mb-2">版本差异对比</h3>
          <form phx-submit="compute_diff" class="flex flex-wrap gap-2 items-end mb-4">
            <div>
              <label class="label"><span class="label-text">版本 A</span></label>
              <select name="a" class="select select-bordered select-sm">
                {Phoenix.HTML.Form.options_for_select(version_numbers(@versions), @diff_selection[:a])}
              </select>
            </div>
            <div>
              <label class="label"><span class="label-text">版本 B</span></label>
              <select name="b" class="select select-bordered select-sm">
                {Phoenix.HTML.Form.options_for_select(version_numbers(@versions), @diff_selection[:b])}
              </select>
            </div>
            <button type="submit" class="btn btn-sm">对比</button>
          </form>

          <div :if={@diff_result == []} class="text-sm text-base-content/60">两个版本内容一致。</div>
          <div :if={@diff_result != nil and @diff_result != []} class="space-y-2">
            <div
              :for={change <- @diff_result}
              class="border-l-4 pl-3 py-1 text-sm"
              style={border_color(change.change)}
            >
              <div class="font-semibold">
                {change.field} <span class="text-xs opacity-60">({change.change})</span>
              </div>
              <div :if={change.before not in [nil, ""]} class="text-error line-through">
                {inspect_val(change.before)}
              </div>
              <div :if={change.after_value not in [nil, ""]} class="text-success">
                {inspect_val(change.after_value)}
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp review_tab(assigns) do
    ~H"""
    <div class="card bg-base-100 border border-base-200">
      <div class="card-body space-y-4">
        <h3 class="font-semibold">复核流程</h3>

        <div :if={@alert.status == :draft} class="alert alert-info">
          <span>当前为草稿状态，提交后进入待复核。</span>
          <.button phx-click="submit_for_review" variant="primary" class="btn-sm">提交复核</.button>
        </div>

        <div :if={@alert.status == :in_review} class="space-y-4">
          <div class="alert alert-warning">
            <.icon name="hero-clock" class="size-5" />
            <span>该草稿正在复核中。复核结论绑定当前修订 r{@alert.draft_revision}；若草稿被修改，旧结论将自动失效。</span>
          </div>
          <.form for={@review_form} id="review-form" phx-submit="review_decision" class="space-y-3">
            <.input field={@review_form[:comment]} type="textarea" label="复核意见" rows="3" />
            <div class="flex gap-2">
              <button type="submit" name="decision" value="approved" class="btn btn-success btn-sm">通过</button>
              <button
                type="submit"
                name="decision"
                value="changes_requested"
                class="btn btn-warning btn-sm"
              >要求修改</button>
              <button type="submit" name="decision" value="rejected" class="btn btn-error btn-sm">驳回</button>
            </div>
          </.form>
        </div>

        <div :if={@alert.status == :approved} class="alert alert-success">
          <.icon name="hero-check-circle" class="size-5" />
          <span>已通过复核，可进入发布环节。</span>
        </div>

        <div :if={@alert.status == :rejected} class="alert alert-error">
          <.icon name="hero-x-circle" class="size-5" />
          <span>复核未通过，请回到草稿修改后重新提交。</span>
        </div>

        <div class="divider"></div>
        <h4 class="font-semibold text-sm">历史复核记录</h4>
        <table class="table table-sm">
          <thead>
            <tr>
              <th>结论</th><th>修订</th><th>是否失效</th><th>意见</th><th>复核人</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={v <- Enum.filter(@versions, fn v -> v.status in [:approved, :rejected] end)}>
              <td>{v.status}</td>
              <td class="font-mono">r{v.revision_seed}</td>
              <td>{if v.revision_seed != @alert.draft_revision, do: "已失效", else: "当前"}</td>
              <td class="text-xs">{v.review_note}</td>
              <td>{v.created_by}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp publish_tab(assigns) do
    ~H"""
    <div class="card bg-base-100 border border-base-200">
      <div class="card-body space-y-4">
        <h3 class="font-semibold">发布</h3>

        <div :if={@alert.status == :published} class="alert alert-success">
          <.icon name="hero-check-badge" class="size-5" />
          <span>预警已于版本 #{@alert.latest_published_version} 发布，内容不可修改。后续变更必须走更正或解除。</span>
        </div>

        <div :if={@alert.status == :canceled} class="alert alert-error">
          <span>该预警已解除。</span>
        </div>

        <div :if={@alert.status == :approved} class="space-y-3">
          <div class="alert alert-info">
            <span>仅最新通过复核且未被后续草稿修改的版本可以发布。发布将创建不可变版本快照和通知 outbox。</span>
          </div>
          <.button phx-click="publish" variant="primary">
            <.icon name="hero-paper-airplane" class="size-4" /> 发布当前已复核版本
          </.button>
        </div>

        <div :if={@alert.status in [:draft, :in_review, :rejected]} class="alert alert-warning">
          <span>预警尚未通过复核，无法发布。请先完成复核流程。</span>
        </div>
      </div>
    </div>
    """
  end

  defp followup_tab(assigns) do
    ~H"""
    <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
      <div class="card bg-base-100 border border-base-200">
        <div class="card-body space-y-3">
          <h3 class="font-semibold">发布更正（Update）</h3>
          <p :if={@alert.status != :published} class="text-sm text-base-content/60">
            仅已发布的预警可以创建更正。
          </p>
          <.form
            :if={@alert.status == :published}
            for={@correction_form}
            id="correction-form"
            phx-submit="create_correction"
            class="space-y-3"
          >
            <.input field={@correction_form[:headline]} label="更正标题" />
            <.input
              field={@correction_form[:description]}
              type="textarea"
              label="更正描述"
              rows="3"
            />
            <.input
              field={@correction_form[:instruction]}
              type="textarea"
              label="更正处置建议"
              rows="2"
            />
            <.input field={@correction_form[:note]} label="更正说明" />
            <button type="submit" class="btn btn-primary btn-sm">提交更正并发布</button>
          </.form>
        </div>
      </div>

      <div class="card bg-base-100 border border-base-200">
        <div class="card-body space-y-3">
          <h3 class="font-semibold">解除预警（Cancel）</h3>
          <p :if={@alert.status != :published} class="text-sm text-base-content/60">
            仅已发布的预警可以解除。
          </p>
          <.form
            :if={@alert.status == :published}
            for={@cancellation_form}
            id="cancellation-form"
            phx-submit="create_cancellation"
            class="space-y-3"
          >
            <.input field={@cancellation_form[:note]} type="textarea" label="解除原因" rows="3" />
            <button type="submit" class="btn btn-error btn-sm">确认解除并发布</button>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  defp audit_tab(assigns) do
    ~H"""
    <div class="card bg-base-100 border border-base-200">
      <div class="card-body">
        <h3 class="font-semibold mb-3">审计事件与通知 outbox</h3>
        <table class="table table-sm">
          <thead>
            <tr>
              <th>时间</th><th>动作</th><th>摘要</th><th>操作人</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={event <- @audits}>
              <td class="text-xs font-mono">
                {Calendar.strftime(event.occurred_at, "%Y-%m-%d %H:%M:%S")}
              </td>
              <td class="font-mono text-xs">{event.action}</td>
              <td>{event.summary}</td>
              <td>{event.actor}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp enum_options(values) do
    Enum.map(values, fn v -> {humanize(v), Atom.to_string(v)} end)
  end

  defp version_numbers(versions) do
    versions
    |> Enum.map(&{&1.version_number, &1.version_number})
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp humanize(atom) do
    atom
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp border_color(:added), do: "border-l-success"
  defp border_color(:removed), do: "border-l-error"
  defp border_color(:modified), do: "border-l-warning"
  defp border_color(_), do: "border-l-base-300"

  defp inspect_val(value) when is_list(value), do: Enum.join(value, ", ")
  defp inspect_val(value), do: to_string(value)
end
