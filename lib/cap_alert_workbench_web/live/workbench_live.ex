defmodule CapAlertWorkbenchWeb.WorkbenchLive do
  @moduledoc """
  预警编审工作台 LiveView。

  只调用 `CapAlertWorkbench.Alerts` 公开用例，绝不直接写状态字段。
  通过 PubSub 订阅消息流，其他浏览器的修改会实时推送刷新。

  草稿表单按 info 段组织（每段独立的 severity/headline/description/area），
  支持拆分/删除 info 段，保存时经 `Alerts.compose_payload/2` 合成 payload。
  """
  use CapAlertWorkbenchWeb, :live_view

  alias CapAlertWorkbench.Alerts
  alias CapAlertWorkbench.Cap.{Enums, Lifecycle}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        page_title: "预警编审工作台",
        actor: "duty-officer",
        reviewer: "reviewer-1",
        detail: nil,
        diff: nil,
        xml_preview: nil,
        draft_form: nil,
        draft_infos: [],
        review_note: ""
      )
      |> stream(:streams, Alerts.list_streams())

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"stream_id" => id}, _uri, socket) do
    if connected?(socket), do: Alerts.subscribe(id)
    {:noreply, load_detail(socket, id)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, detail: nil, diff: nil, xml_preview: nil)}
  end

  defp load_detail(socket, id) do
    case Alerts.get_stream_detail(id) do
      {:ok, detail} ->
        socket
        |> assign(
          detail: detail,
          diff: nil,
          xml_preview: nil,
          page_title: detail.stream.identifier
        )
        |> assign_draft_form(detail.active_draft)

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "消息流不存在")
        |> push_navigate(to: ~p"/")
    end
  end

  defp assign_draft_form(socket, nil) do
    assign(socket, draft_form: nil, draft_infos: [])
  end

  defp assign_draft_form(socket, version) do
    infos =
      (version.payload["infos"] || [])
      |> Enum.map(&info_to_form_params/1)

    form_params = %{
      "status" => version.payload["status"],
      "lock_version" => version.lock_version,
      "infos" => infos |> Enum.with_index() |> Map.new(fn {info, i} -> {to_string(i), info} end)
    }

    assign(socket,
      draft_form: to_form(form_params, as: :draft),
      draft_infos: infos
    )
  end

  defp info_to_form_params(info) do
    geocodes =
      (info["areas"] || [])
      |> Enum.flat_map(fn area -> area["geocodes"] || [] end)
      |> Enum.map_join(", ", fn gc -> gc["value"] end)

    area_desc =
      case info["areas"] do
        [area | _] -> area["area_desc"]
        _ -> nil
      end

    %{
      "event" => info["event"],
      "headline" => info["headline"],
      "description" => info["description"],
      "instruction" => info["instruction"],
      "language" => info["language"],
      "category" => info["category"],
      "urgency" => info["urgency"],
      "severity" => info["severity"],
      "certainty" => info["certainty"],
      "effective" => info["effective"],
      "expires" => info["expires"],
      "geocodes" => geocodes,
      "area_desc" => area_desc
    }
  end

  # -------------------------------------------------------------------
  # 事件：全部委托 Alerts 用例层
  # -------------------------------------------------------------------

  @impl true
  def handle_event("set_actor", %{"actor" => actor, "reviewer" => reviewer}, socket) do
    {:noreply,
     assign(socket,
       actor: blank_default(actor, "duty-officer"),
       reviewer: blank_default(reviewer, "reviewer-1")
     )}
  end

  # 表单输入同步（不持久化），供拆分/删除 info 段时保留未保存输入
  def handle_event("form_changed", %{"draft" => params}, socket) do
    {:noreply, assign(socket, draft_infos: infos_from_params(params))}
  end

  # 拆分 info 段（复制末段内容，清空地区）
  def handle_event("save_draft", %{"draft" => params, "form_action" => "add_info"}, socket) do
    infos = infos_from_params(params)

    template =
      case List.last(infos) do
        nil -> info_to_form_params(%{})
        last -> last
      end

    new_info = %{
      template
      | "geocodes" => "",
        "area_desc" => "",
        "headline" => "",
        "description" => ""
    }

    {:noreply, rebuild_form(socket, params, infos ++ [new_info])}
  end

  # 删除指定 info 段
  def handle_event(
        "save_draft",
        %{"draft" => params, "form_action" => "remove_info:" <> index},
        socket
      ) do
    infos = infos_from_params(params) |> List.delete_at(String.to_integer(index))
    {:noreply, rebuild_form(socket, params, infos)}
  end

  def handle_event("save_draft", %{"draft" => params}, socket) do
    version = socket.assigns.detail.active_draft
    {lock, _} = Integer.parse(to_string(params["lock_version"]))

    case Alerts.compose_payload(version, params) do
      {:ok, payload} ->
        case Alerts.update_draft(version.id, %{payload: payload}, lock, socket.assigns.actor) do
          {:ok, _updated} ->
            {:noreply, socket |> put_flash(:info, "草稿已保存") |> reload_detail()}

          {:error, reason} ->
            {:noreply, socket |> put_flash(:error, error_message(reason)) |> reload_detail()}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("submit_review", %{"lock_version" => lock}, socket) do
    version = socket.assigns.detail.active_draft
    {lock, _} = Integer.parse(to_string(lock))

    case Alerts.submit_for_review(version.id, lock, socket.assigns.actor) do
      {:ok, _version} ->
        {:noreply, socket |> put_flash(:info, "已提交复核") |> reload_detail()}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, error_message(reason)) |> reload_detail()}
    end
  end

  def handle_event(
        "decide_review",
        %{"decision" => decision, "pinned_lock_version" => pin, "note" => note},
        socket
      ) do
    version = socket.assigns.detail.active_draft
    {pin, _} = Integer.parse(to_string(pin))

    decision_atom =
      case decision do
        "approved" -> :approved
        "rejected" -> :rejected
      end

    case Alerts.decide_review(version.id, decision_atom, note, socket.assigns.reviewer, pin) do
      {:ok, _version} ->
        message = if decision_atom == :approved, do: "复核通过", else: "已退回修改"
        {:noreply, socket |> put_flash(:info, message) |> reload_detail()}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, error_message(reason)) |> reload_detail()}
    end
  end

  def handle_event("publish", %{"version_id" => id}, socket) do
    case Alerts.publish(id, socket.assigns.actor) do
      {:ok, _published} ->
        {:noreply, socket |> put_flash(:info, "发布成功，通知已写入 outbox") |> reload_detail()}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, error_message(reason)) |> reload_detail()}
    end
  end

  def handle_event("start_correction", _params, socket) do
    case Alerts.start_correction(socket.assigns.detail.stream.id, socket.assigns.actor) do
      {:ok, _version} ->
        {:noreply, socket |> put_flash(:info, "已基于最新发布版本创建更正草稿") |> reload_detail()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("start_cancellation", _params, socket) do
    case Alerts.start_cancellation(socket.assigns.detail.stream.id, socket.assigns.actor) do
      {:ok, _version} ->
        {:noreply, socket |> put_flash(:info, "已基于最新发布版本创建解除草稿") |> reload_detail()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("diff", %{"a" => a_id, "b" => b_id}, socket) do
    with {:ok, a} <- Alerts.get_version(a_id),
         {:ok, b} <- Alerts.get_version(b_id) do
      {:noreply,
       assign(socket,
         diff: %{
           a: a,
           b: b,
           rows: Alerts.diff_versions(a, b),
           areas: Alerts.diff_areas(a, b)
         }
       )}
    else
      {:error, _} -> {:noreply, put_flash(socket, :error, "版本不存在")}
    end
  end

  def handle_event("export_xml", %{"version_id" => id}, socket) do
    case Alerts.export_cap_xml(id) do
      {:ok, xml} -> {:noreply, assign(socket, xml_preview: %{version_id: id, xml: xml})}
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("close_xml", _params, socket) do
    {:noreply, assign(socket, xml_preview: nil)}
  end

  @impl true
  def handle_info({:stream_updated, id, origin}, socket) do
    if socket.assigns.detail && to_string(socket.assigns.detail.stream.id) == to_string(id) do
      socket = load_detail(socket, id)

      # 本进程发起的操作已给出操作反馈，不再用广播提示覆盖
      socket =
        if origin == self() do
          socket
        else
          put_flash(socket, :info, "数据已在其他会话更新，已刷新")
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  defp reload_detail(socket) do
    load_detail(socket, socket.assigns.detail.stream.id)
  end

  defp rebuild_form(socket, params, infos) do
    form_params = %{
      "status" => params["status"],
      "lock_version" => params["lock_version"],
      "infos" => infos |> Enum.with_index() |> Map.new(fn {info, i} -> {to_string(i), info} end)
    }

    assign(socket,
      draft_form: to_form(form_params, as: :draft),
      draft_infos: infos
    )
  end

  defp infos_from_params(params) do
    (params["infos"] || %{})
    |> Enum.sort_by(fn {index, _fields} -> String.to_integer(index) end)
    |> Enum.map(fn {_index, fields} -> fields end)
  end

  defp blank_default("", default), do: default
  defp blank_default(nil, default), do: default
  defp blank_default(value, _default), do: value

  # -------------------------------------------------------------------
  # 错误文案（错误码与 API 一致）
  # -------------------------------------------------------------------

  defp error_message(:stale_lock),
    do: "乐观锁冲突：草稿已被他人修改，页面已刷新，请基于最新内容重新编辑"

  defp error_message(:stale_review), do: "复核结论已失效：复核期间草稿被修改，请重新复核"
  defp error_message(:already_published), do: "该版本已发布，不能重复发布"

  defp error_message({:not_publishable, workflow}),
    do: "当前状态不可发布（#{workflow}），需先复核通过"

  defp error_message(:not_latest_version), do: "只有最新草稿版本可以发布"
  defp error_message(:draft_already_exists), do: "已存在未发布草稿，不能同时发起多个更正/解除"

  defp error_message({:invalid_transition, from, event}),
    do: "非法状态转换：#{from} 不能执行 #{event}"

  defp error_message({:unknown_enum, kind, value}), do: "未知枚举值 #{kind}: #{value}"
  defp error_message(:doctype_forbidden), do: "XML 含 DOCTYPE/实体声明，已拒绝"
  defp error_message({:malformed_xml, msg}), do: "XML 解析失败：#{msg}"

  defp error_message(errors) when is_list(errors) do
    Enum.map_join(errors, "；", fn {field, msg} -> "#{format_field(field)} #{msg}" end)
  end

  defp error_message(other), do: "操作失败：#{inspect(other)}"

  defp format_field({:info, index, field}), do: "info#{index + 1}.#{field}"
  defp format_field(field), do: to_string(field)

  # -------------------------------------------------------------------
  # 渲染辅助
  # -------------------------------------------------------------------

  defp workflow_badge_class(:editing), do: "bg-blue-100 text-blue-800 ring-blue-600/20"
  defp workflow_badge_class(:in_review), do: "bg-amber-100 text-amber-800 ring-amber-600/20"
  defp workflow_badge_class(:approved), do: "bg-emerald-100 text-emerald-800 ring-emerald-600/20"
  defp workflow_badge_class(:published), do: "bg-zinc-200 text-zinc-700 ring-zinc-500/20"

  defp stream_state_badge_class(:drafting), do: "bg-blue-100 text-blue-800 ring-blue-600/20"

  defp stream_state_badge_class(:published),
    do: "bg-emerald-100 text-emerald-800 ring-emerald-600/20"

  defp stream_state_badge_class(:cancelled), do: "bg-zinc-200 text-zinc-700 ring-zinc-500/20"

  defp workflow_label(:editing), do: "编辑中"
  defp workflow_label(:in_review), do: "复核中"
  defp workflow_label(:approved), do: "复核通过"
  defp workflow_label(:published), do: "已发布"

  defp stream_state_label(:drafting), do: "起草中"
  defp stream_state_label(:published), do: "已发布"
  defp stream_state_label(:cancelled), do: "已解除"

  defp msg_type_label(:alert), do: "Alert 首发"
  defp msg_type_label(:update), do: "Update 更正"
  defp msg_type_label(:cancel), do: "Cancel 解除"

  defp area_status_label(:unchanged), do: "未变化"
  defp area_status_label(:changed), do: "有变更"
  defp area_status_label(:added), do: "新增地区"
  defp area_status_label(:removed), do: "移除地区"

  defp area_status_class(:unchanged), do: "bg-zinc-100 text-zinc-600 ring-zinc-500/20"
  defp area_status_class(:changed), do: "bg-amber-100 text-amber-800 ring-amber-600/20"
  defp area_status_class(:added), do: "bg-emerald-100 text-emerald-800 ring-emerald-600/20"
  defp area_status_class(:removed), do: "bg-rose-100 text-rose-800 ring-rose-600/20"

  defp enum_options(kind) do
    Enum.map(Enums.values(kind), &Enums.to_cap(kind, &1))
  end

  defp editable?(version), do: version != nil and Lifecycle.editable?(version.workflow)
end
