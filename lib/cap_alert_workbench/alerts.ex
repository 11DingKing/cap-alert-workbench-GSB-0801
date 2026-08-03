defmodule CapAlertWorkbench.Alerts do
  @moduledoc """
  预警编审工作台的公开用例层。

  LiveView 与 API 控制器只能调用本模块的公开函数；所有状态转换经由
  `CapAlertWorkbench.Cap.Lifecycle` 状态机，所有多步写入包裹在单个
  数据库事务中（版本状态、不可变发布文档、审计事件、通知 outbox 要么
  全部提交，要么全部回滚）。

  并发语义：

    * 草稿编辑：乐观锁 `lock_version`，冲突返回 `{:error, :stale_lock}`
    * 复核：结论钉住 `lock_version`，草稿已变更返回 `{:error, :stale_review}`
    * 发布：stream 行级锁串行化 + 工作流守卫 + 唯一索引，重复发布返回
      `{:error, :already_published}` / `{:error, :not_publishable}`
  """

  import Ecto.Query

  alias CapAlertWorkbench.Alerts.{
    AuditEvent,
    OutboxEvent,
    PublishedDocument,
    ReviewDecision,
    Stream,
    Version
  }

  alias CapAlertWorkbench.Cap.{Document, Enums, Lifecycle, Xml}
  alias CapAlertWorkbench.Repo

  @pubsub CapAlertWorkbench.PubSub

  # -------------------------------------------------------------------
  # 查询
  # -------------------------------------------------------------------

  def list_streams do
    Stream
    |> order_by([s], desc: s.inserted_at)
    |> preload([s], versions: ^from(v in Version, order_by: v.version_number))
    |> Repo.all()
  end

  @doc "工作台详情：stream + 全部版本 + 发布文档 + 审计 + outbox + 复核记录。"
  def get_stream_detail(stream_id) do
    case Repo.get(Stream, stream_id) do
      nil ->
        {:error, :not_found}

      stream ->
        stream =
          Repo.preload(stream,
            versions: [:review_decisions],
            published_documents: :version
          )

        {:ok,
         %{
           stream: stream,
           versions: Enum.sort_by(stream.versions, & &1.version_number),
           active_draft: active_draft(stream.id),
           published_documents:
             Enum.sort_by(stream.published_documents, & &1.sent_at, {:desc, DateTime}),
           audit_events: list_audit_events(stream.id),
           outbox_events: list_outbox_events(stream.id)
         }}
    end
  end

  def get_version(version_id) do
    case Repo.get(Version, version_id) do
      nil -> {:error, :not_found}
      version -> {:ok, version}
    end
  end

  @doc "当前未发布草稿（editing/in_review/approved）。"
  def active_draft(stream_id) do
    Version
    |> where([v], v.stream_id == ^stream_id)
    |> where([v], v.workflow in [:editing, :in_review, :approved])
    |> Repo.one()
  end

  def list_audit_events(stream_id) do
    AuditEvent
    |> where([a], a.stream_id == ^stream_id)
    |> order_by([a], desc: a.inserted_at, desc: a.id)
    |> Repo.all()
  end

  def list_outbox_events(stream_id) do
    OutboxEvent
    |> where([o], o.stream_id == ^stream_id)
    |> order_by([o], desc: o.inserted_at, desc: o.id)
    |> Repo.all()
  end

  # -------------------------------------------------------------------
  # 用例：创建（含导入）
  # -------------------------------------------------------------------

  @doc "创建消息流与首个草稿版本。identifier 全局唯一。"
  def create_stream(attrs, actor) when is_map(attrs) do
    if Repo.get_by(Stream, identifier: Map.fetch!(attrs, :identifier)) do
      {:error, :identifier_taken}
    else
      do_create_stream(attrs, actor)
    end
  end

  defp do_create_stream(attrs, actor) do
    payload = Map.fetch!(attrs, :payload)

    Repo.transaction(fn ->
      stream =
        %Stream{}
        |> Ecto.Changeset.cast(
          %{
            "identifier" => Map.fetch!(attrs, :identifier),
            "sender" => Map.fetch!(attrs, :sender)
          },
          [:identifier, :sender]
        )
        |> Ecto.Changeset.validate_required([:identifier, :sender])
        |> Ecto.Changeset.unique_constraint(:identifier)
        |> Repo.insert!()

      version =
        %Version{stream_id: stream.id, version_number: 1, msg_type: payload_msg_type(payload)}
        |> Version.create_changeset(%{payload: payload, edited_by: actor})
        |> Repo.insert!()

      insert_audit!(stream.id, version.id, :stream_created, actor, %{
        "identifier" => stream.identifier
      })

      %{stream: stream, version: version}
    end)
    |> case do
      {:ok, result} ->
        broadcast(result.stream.id)
        {:ok, result}

      {:error, other} ->
        {:error, other}
    end
  rescue
    Ecto.ConstraintError -> {:error, :identifier_taken}
  end

  @doc "导入 CAP XML：解析（不解析外部实体）→ 校验 → 单事务落库为草稿。"
  def import_cap_xml(xml, actor) when is_binary(xml) do
    with {:ok, doc} <- Xml.parse(xml),
         :ok <- Document.validate(doc),
         :ok <- guard_identifier_available(doc.identifier) do
      Repo.transaction(fn ->
        case do_create_stream(
               %{
                 identifier: doc.identifier,
                 sender: doc.sender,
                 payload: Document.to_map(doc)
               },
               actor
             ) do
          {:ok, %{stream: stream, version: version} = result} ->
            insert_audit!(stream.id, version.id, :imported, actor, %{"source" => "cap_xml"})
            result

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
    end
  end

  defp guard_identifier_available(identifier) do
    if Repo.get_by(Stream, identifier: identifier) do
      {:error, :identifier_taken}
    else
      :ok
    end
  end

  # -------------------------------------------------------------------
  # 用例：编辑草稿（乐观锁）
  # -------------------------------------------------------------------

  @doc """
  编辑草稿内容。`expected_lock_version` 来自客户端表单；
  版本不可编辑或锁冲突时返回错误，绝不直接写状态字段。
  """
  def update_draft(version_id, attrs, expected_lock_version, actor) do
    with {:ok, version} <- get_version(version_id) do
      if Lifecycle.editable?(version.workflow) do
        payload = Map.fetch!(attrs, :payload)

        Repo.transaction(fn ->
          # 复核中改稿：保持 :in_review（状态机 :revise 事件），仅递增乐观锁
          event = if version.workflow == :in_review, do: :revise, else: :edit
          {:ok, _state} = transition_for_edit(version.workflow, event)

          data = %{version | lock_version: expected_lock_version}

          updated =
            data
            |> Version.edit_changeset(%{payload: payload, edited_by: actor})
            |> Repo.update!()

          insert_audit!(version.stream_id, version.id, :draft_updated, actor, %{
            "lock_version" => updated.lock_version
          })

          updated
        end)
        |> unwrap_tx(version.stream_id)
      else
        {:error, {:invalid_transition, version.workflow, :edit}}
      end
    end
  rescue
    Ecto.StaleEntryError -> {:error, :stale_lock}
  end

  defp transition_for_edit(workflow, :revise), do: Lifecycle.transition_draft(workflow, :revise)

  defp transition_for_edit(workflow, :edit) when workflow in [:editing, :in_review],
    do: {:ok, workflow}

  # -------------------------------------------------------------------
  # 用例：提交复核
  # -------------------------------------------------------------------

  def submit_for_review(version_id, expected_lock_version, actor) do
    guarded_transition(version_id, :editing, :submit_review, expected_lock_version, fn version ->
      insert_audit!(version.stream_id, version.id, :submitted_for_review, actor, %{
        "lock_version" => expected_lock_version
      })
    end)
  end

  # -------------------------------------------------------------------
  # 用例：复核（结论钉住复核时的 lock_version）
  # -------------------------------------------------------------------

  @doc """
  复核。`pinned_lock_version` 为复核人打开页面时的乐观锁版本；
  若草稿此后被修改（锁号变化）或状态已流转，本结论作废。
  """
  def decide_review(version_id, decision, note, reviewer, pinned_lock_version)
      when decision in [:approved, :rejected] do
    event = if decision == :approved, do: :approve, else: :reject

    case guarded_transition(version_id, :in_review, event, pinned_lock_version, fn version ->
           %ReviewDecision{
             version_id: version.id,
             decision: decision,
             reviewer: reviewer,
             note: note,
             pinned_lock_version: pinned_lock_version
           }
           |> Repo.insert!()

           insert_audit!(
             version.stream_id,
             version.id,
             if(decision == :approved, do: :review_approved, else: :review_rejected),
             reviewer,
             %{"note" => note, "pinned_lock_version" => pinned_lock_version}
           )
         end) do
      {:error, :stale_lock} -> {:error, :stale_review}
      other -> other
    end
  end

  # -------------------------------------------------------------------
  # 用例：发布（事务：版本状态 + 不可变文档 + stream 状态 + 审计 + outbox）
  # -------------------------------------------------------------------

  @doc """
  发布已复核通过的最新草稿版本。

  单个事务内完成：stream 行锁 → 最新版本检查 → 工作流守卫更新
  （approved→published）→ 冻结 CAP XML 写入不可变发布文档 → stream
  状态机转换 → 审计 → outbox。任一步失败全部回滚。
  """
  def publish(version_id, actor) do
    with {:ok, version} <- get_version(version_id) do
      version
      |> publish_multi(actor)
      |> Repo.transaction()
      |> case do
        {:ok, %{published: published}} -> {:ok, published}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  @doc """
  构建发布的 `Ecto.Multi`。作为服务层公开，便于调用方（含测试）
  组合额外步骤并复用同一事务语义。
  """
  def publish_multi(%Version{} = version, actor) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:stream, fn repo, _changes ->
      stream = repo.one!(from(s in Stream, where: s.id == ^version.stream_id, lock: "FOR UPDATE"))
      {:ok, stream}
    end)
    |> Ecto.Multi.run(:guard, fn repo, %{stream: stream} ->
      with :ok <- guard_latest_version(repo, stream.id, version),
           :ok <- guard_not_published(version),
           {:ok, _to} <- Lifecycle.transition_draft(version.workflow, :publish),
           {1, _} <-
             repo.update_all(
               from(v in Version,
                 where: v.id == ^version.id and v.workflow == :approved,
                 update: [set: [workflow: :published, updated_at: ^now()]]
               ),
               []
             ) do
        {:ok, :guarded}
      else
        {0, _} ->
          case repo.get(Version, version.id) do
            %Version{workflow: :published} -> {:error, :already_published}
            %Version{workflow: current} -> {:error, {:not_publishable, current}}
            nil -> {:error, :not_found}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end)
    |> Ecto.Multi.run(:published, fn repo, %{stream: stream} ->
      fresh = repo.get!(Version, version.id)
      {:ok, doc} = Document.from_map(fresh.payload)
      doc = %{doc | sent: format_sent_now()}

      with :ok <- Document.validate(doc) do
        cap_xml = Xml.serialize(doc)

        published =
          %PublishedDocument{
            stream_id: stream.id,
            version_id: fresh.id,
            identifier: doc.identifier,
            msg_type: doc.msg_type,
            cap_xml: cap_xml,
            sent_at: DateTime.utc_now()
          }
          |> repo.insert!()

        # 冻结 sent 回写版本 payload，保证版本与发布文档逐字节一致
        frozen_payload = Document.to_map(doc)

        {1, _} =
          repo.update_all(
            from(v in Version,
              where: v.id == ^fresh.id,
              update: [set: [payload: ^frozen_payload]]
            ),
            []
          )

        {:ok, %{published | cap_xml: cap_xml}}
      end
    end)
    |> Ecto.Multi.run(:stream_state, fn repo, %{stream: stream, published: published} ->
      event = if published.msg_type == :cancel, do: :publish_cancel, else: :publish

      with {:ok, to_state} <- Lifecycle.transition_stream(stream.state, event) do
        {1, _} =
          repo.update_all(
            from(s in Stream,
              where: s.id == ^stream.id,
              update: [set: [state: ^to_state, updated_at: ^now()]]
            ),
            []
          )

        {:ok, to_state}
      end
    end)
    |> Ecto.Multi.run(:audit, fn _repo, %{published: published} ->
      audit =
        insert_audit!(published.stream_id, published.version_id, :published, actor, %{
          "msg_type" => to_string(published.msg_type)
        })

      {:ok, audit}
    end)
    |> Ecto.Multi.run(:outbox, fn repo, %{published: published} ->
      type =
        case published.msg_type do
          :alert -> :alert_published
          :update -> :alert_corrected
          :cancel -> :alert_cancelled
        end

      outbox =
        repo.insert!(%OutboxEvent{
          stream_id: published.stream_id,
          version_id: published.version_id,
          type: type,
          payload: %{
            "identifier" => published.identifier,
            "msg_type" => to_string(published.msg_type),
            "sent_at" => DateTime.to_iso8601(published.sent_at)
          }
        })

      {:ok, outbox}
    end)
  end

  defp guard_not_published(%Version{workflow: :published}), do: {:error, :already_published}
  defp guard_not_published(%Version{}), do: :ok

  defp guard_latest_version(repo, stream_id, version) do
    latest =
      repo.one!(
        from(v in Version, where: v.stream_id == ^stream_id, select: max(v.version_number))
      )

    if latest == version.version_number, do: :ok, else: {:error, :not_latest_version}
  end

  # -------------------------------------------------------------------
  # 用例：更正 / 解除（基于最新已发布文档创建新草稿）
  # -------------------------------------------------------------------

  def start_correction(stream_id, actor), do: start_followup(stream_id, :update, actor)

  def start_cancellation(stream_id, actor), do: start_followup(stream_id, :cancel, actor)

  defp start_followup(stream_id, msg_type, actor) when msg_type in [:update, :cancel] do
    Repo.transaction(fn ->
      stream = Repo.one!(from(s in Stream, where: s.id == ^stream_id, lock: "FOR UPDATE"))

      unless stream.state == :published do
        Repo.rollback({:invalid_transition, stream.state, :start_followup})
      end

      latest_published =
        Repo.one!(
          from(p in PublishedDocument,
            where: p.stream_id == ^stream_id,
            order_by: [desc: p.sent_at, desc: p.id],
            limit: 1
          )
        )

      source_version = Repo.get!(Version, latest_published.version_id)
      {:ok, source_doc} = Document.from_map(source_version.payload)

      # 后续消息（更正/解除）统一按已发布跟进文档数顺序编号：-C1、-C2…
      # 第 1 轮更正为 -C1，其后的解除为 -C2，以此类推。
      followup_number =
        Repo.one!(
          from(p in PublishedDocument,
            where: p.stream_id == ^stream_id and p.msg_type in [:update, :cancel],
            select: count(p.id)
          )
        ) + 1

      followup_doc = %{
        source_doc
        | identifier: stream.identifier <> "-C#{followup_number}",
          msg_type: msg_type,
          references: [
            %{
              sender: source_doc.sender,
              identifier: source_doc.identifier,
              sent: source_doc.sent
            }
          ]
      }

      next_number =
        (Repo.one(
           from(v in Version, where: v.stream_id == ^stream_id, select: max(v.version_number))
         ) ||
           0) + 1

      version =
        %Version{stream_id: stream.id, version_number: next_number, msg_type: msg_type}
        |> Version.create_changeset(%{payload: Document.to_map(followup_doc), edited_by: actor})
        |> Repo.insert!()

      insert_audit!(
        stream.id,
        version.id,
        if(msg_type == :update, do: :correction_started, else: :cancellation_started),
        actor,
        %{"based_on_version_id" => source_version.id}
      )

      version
    end)
    |> unwrap_tx(stream_id)
  rescue
    Ecto.ConstraintError -> {:error, :draft_already_exists}
  end

  # -------------------------------------------------------------------
  # 用例：导出与版本差异
  # -------------------------------------------------------------------

  @doc """
  把编辑表单/API 字段参数合成新的版本 payload。

  两种形态：

    * 多 info 段：`%{"infos" => %{"0" => %{...}, "1" => %{...}}}`，
      每个 info 段独立携带 severity/headline/description/area 等；
    * 扁平单 info：`%{"headline" => ..., "severity" => ...}`，
      仅作用于首个 info 段（兼容旧 API 调用）。

  保留原文档的稳定字段（identifier、sender、references、未知扩展字段），
  枚举经 `Enums.from_cap/2` 严格映射。
  """
  def compose_payload(%Version{} = version, params) when is_map(params) do
    with {:ok, doc} <- Document.from_map(version.payload),
         {:ok, doc} <- apply_edit_params(doc, params),
         :ok <- Document.validate(doc) do
      {:ok, Document.to_map(doc)}
    end
  end

  defp apply_edit_params(doc, %{"infos" => infos_params} = params)
       when is_map(infos_params) do
    with {:ok, status} <- enum_param(params, "status", :status, doc.status),
         {:ok, infos} <- build_infos(doc.infos, infos_params) do
      {:ok, %{doc | status: status, infos: infos}}
    end
  end

  defp apply_edit_params(doc, params) do
    # 扁平形态：仅编辑首个 info 段，其余 info 段保持不变
    with {:ok, status} <- enum_param(params, "status", :status, doc.status),
         {:ok, first} <- apply_info_params(first_info(doc), params) do
      infos = [first | Enum.drop(doc.infos, 1)]
      {:ok, %{doc | status: status, infos: infos}}
    end
  end

  defp first_info(%Document{infos: [first | _]}), do: first
  defp first_info(%Document{infos: []}), do: %CapAlertWorkbench.Cap.Info{}

  defp build_infos(existing, infos_params) do
    infos_params
    |> Enum.sort_by(fn {index, _fields} -> String.to_integer(index) end)
    |> Enum.reduce_while({:ok, []}, fn {index, fields}, {:ok, acc} ->
      base = Enum.at(existing, String.to_integer(index)) || %CapAlertWorkbench.Cap.Info{}

      case apply_info_params(base, stringify_keys(fields)) do
        {:ok, info} -> {:cont, {:ok, [info | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, infos} -> {:ok, Enum.reverse(infos)}
      error -> error
    end
  end

  defp apply_info_params(info, params) do
    with {:ok, category} <- enum_param(params, "category", :category, info.category),
         {:ok, urgency} <- enum_param(params, "urgency", :urgency, info.urgency),
         {:ok, severity} <- enum_param(params, "severity", :severity, info.severity),
         {:ok, certainty} <- enum_param(params, "certainty", :certainty, info.certainty) do
      geocodes = parse_geocodes(Map.get(params, "geocodes"))

      areas =
        case {Map.get(params, "area_desc"), geocodes} do
          {nil, nil} ->
            info.areas

          {area_desc, codes} ->
            [
              %{
                area_desc: area_desc || current_area_desc(info),
                geocodes: codes || current_geocodes(info)
              }
            ]
        end

      {:ok,
       %{
         info
         | category: category,
           urgency: urgency,
           severity: severity,
           certainty: certainty,
           language: blank_to(Map.get(params, "language"), info.language),
           event: blank_to(Map.get(params, "event"), info.event),
           headline: blank_to(Map.get(params, "headline"), info.headline),
           description: blank_to(Map.get(params, "description"), info.description),
           instruction: blank_to(Map.get(params, "instruction"), info.instruction),
           effective: blank_to(Map.get(params, "effective"), info.effective),
           expires: blank_to(Map.get(params, "expires"), info.expires),
           areas: areas
       }}
    end
  end

  defp enum_param(params, key, kind, current) do
    case Map.get(params, key) do
      nil -> {:ok, current}
      "" -> {:ok, current}
      value -> CapAlertWorkbench.Cap.Enums.from_cap(kind, value)
    end
  end

  defp blank_to(nil, current), do: current
  defp blank_to("", _current), do: nil
  defp blank_to(value, _current), do: value

  defp parse_geocodes(nil), do: nil

  defp parse_geocodes(value) when is_binary(value) do
    value
    |> String.split([",", "，", " "], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&%{value_name: "region", value: &1})
  end

  defp parse_geocodes(value) when is_list(value) do
    Enum.map(value, fn
      %{"value" => code} -> %{value_name: "region", value: code}
      code when is_binary(code) -> %{value_name: "region", value: code}
    end)
  end

  defp current_area_desc(info) do
    case info.areas do
      [area | _] -> area.area_desc
      [] -> nil
    end
  end

  defp current_geocodes(info) do
    case info.areas do
      [area | _] -> area.geocodes
      [] -> []
    end
  end

  @doc "导出版本为 CAP XML 文本（经服务层序列化）。"
  def export_cap_xml(version_id) do
    with {:ok, version} <- get_version(version_id),
         {:ok, doc} <- Document.from_map(version.payload) do
      {:ok, Xml.serialize(doc)}
    end
  end

  @doc """
  两个版本的字段级差异。返回 `%{path => {old_value, new_value | nil}}`，
  值均为展示用字符串。路径示例：`severity`（alert 级不含）、
  `info1.severity`、`info2.geocodes`。
  """
  def diff_versions(%Version{} = a, %Version{} = b) do
    flat_a = flatten_payload(a.payload)
    flat_b = flatten_payload(b.payload)

    paths = (Map.keys(flat_a) ++ Map.keys(flat_b)) |> Enum.uniq() |> Enum.sort()

    Map.new(paths, fn path ->
      {path, {Map.get(flat_a, path), Map.get(flat_b, path)}}
    end)
    |> Enum.reject(fn {_path, {old, new}} -> old == new end)
    |> Map.new()
  end

  @area_tracked_fields ~w(severity urgency certainty headline description event)

  @doc """
  按地区（geocode）对比两个版本。

  返回 `[%{geocode, status, changes}]`：status 为
  `:unchanged | :changed | :added | :removed`；changes 为
  `[{field, old, new}]`，例如 `{"severity", "Severe", "Extreme"}`。
  用于差异页展示「440800 未变化、440900 Severe→Extreme」。
  """
  def diff_areas(%Version{} = a, %Version{} = b) do
    with {:ok, doc_a} <- Document.from_map(a.payload),
         {:ok, doc_b} <- Document.from_map(b.payload) do
      index_a = area_index(doc_a)
      index_b = area_index(doc_b)

      (Map.keys(index_a) ++ Map.keys(index_b))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn geocode ->
        case {Map.get(index_a, geocode), Map.get(index_b, geocode)} do
          {nil, new} ->
            %{geocode: geocode, status: :added, changes: field_changes(%{}, new)}

          {old, nil} ->
            %{geocode: geocode, status: :removed, changes: field_changes(old, %{})}

          {old, new} ->
            case field_changes(old, new) do
              [] -> %{geocode: geocode, status: :unchanged, changes: []}
              changes -> %{geocode: geocode, status: :changed, changes: changes}
            end
        end
      end)
    end
  end

  defp area_index(%Document{} = doc) do
    for info <- doc.infos, geocode <- CapAlertWorkbench.Cap.Info.geocodes(info), reduce: %{} do
      acc ->
        Map.put(acc, geocode, %{
          "severity" => Enums.to_cap(:severity, info.severity),
          "urgency" => Enums.to_cap(:urgency, info.urgency),
          "certainty" => Enums.to_cap(:certainty, info.certainty),
          "headline" => info.headline,
          "description" => info.description,
          "event" => info.event
        })
    end
  end

  defp field_changes(old, new) do
    Enum.flat_map(@area_tracked_fields, fn field ->
      old_value = Map.get(old, field)
      new_value = Map.get(new, field)

      if old_value == new_value do
        []
      else
        [{field, old_value, new_value}]
      end
    end)
  end

  defp flatten_payload(payload) do
    alert_scalars = Map.take(payload, ~w(identifier sender sent status msg_type scope))

    references =
      (payload["references"] || [])
      |> Enum.map_join("; ", fn ref -> "#{ref["sender"]},#{ref["identifier"]},#{ref["sent"]}" end)

    infos_flat =
      (payload["infos"] || [])
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {info, index} ->
        geocodes =
          (info["areas"] || [])
          |> Enum.flat_map(fn area -> area["geocodes"] || [] end)
          |> Enum.map_join(", ", fn gc -> "#{gc["value_name"]}=#{gc["value"]}" end)

        area_desc =
          case info["areas"] do
            [area | _] -> area["area_desc"]
            _ -> nil
          end

        prefix = "info#{index}"

        %{
          "#{prefix}.event" => info["event"],
          "#{prefix}.severity" => info["severity"],
          "#{prefix}.urgency" => info["urgency"],
          "#{prefix}.certainty" => info["certainty"],
          "#{prefix}.headline" => info["headline"],
          "#{prefix}.description" => info["description"],
          "#{prefix}.instruction" => info["instruction"],
          "#{prefix}.area_desc" => area_desc,
          "#{prefix}.geocodes" => geocodes,
          "#{prefix}.extensions" => "#{length(info["extensions"] || [])} 个扩展元素"
        }
      end)
      |> Map.new()

    alert_scalars
    |> Map.put("references", references)
    |> Map.put("extensions", "#{length(payload["extensions"] || [])} 个扩展元素")
    |> Map.merge(infos_flat)
    |> Map.new(fn {k, v} -> {k, to_string(v || "")} end)
  end

  # -------------------------------------------------------------------
  # 内部：带守卫的状态转换（update_all 原子 check-and-set）
  # -------------------------------------------------------------------

  defp guarded_transition(version_id, from_state, event, expected_lock_version, side_effects) do
    with {:ok, version} <- get_version(version_id),
         {:ok, to_state} <- Lifecycle.transition_draft(from_state, event) do
      Repo.transaction(fn ->
        {count, _} =
          Repo.update_all(
            from(v in Version,
              where:
                v.id == ^version_id and v.workflow == ^from_state and
                  v.lock_version == ^expected_lock_version,
              update: [set: [workflow: ^to_state, updated_at: ^now()]]
            ),
            []
          )

        case count do
          1 ->
            side_effects.(version)
            Repo.get!(Version, version_id)

          0 ->
            current = Repo.get!(Version, version_id)

            Repo.rollback(
              if current.lock_version != expected_lock_version and current.workflow == from_state do
                :stale_lock
              else
                {:invalid_transition, current.workflow, event}
              end
            )
        end
      end)
      |> unwrap_tx(version.stream_id)
    end
  end

  defp unwrap_tx({:ok, result}, stream_id) do
    broadcast(stream_id)
    {:ok, result}
  end

  defp unwrap_tx({:error, reason}, _stream_id), do: {:error, reason}

  defp insert_audit!(stream_id, version_id, event, actor, details) do
    Repo.insert!(%AuditEvent{
      stream_id: stream_id,
      version_id: version_id,
      event: event,
      actor: actor,
      details: details
    })
  end

  defp broadcast(stream_id) do
    Phoenix.PubSub.broadcast(@pubsub, topic(stream_id), {:stream_updated, stream_id, self()})
    :ok
  end

  @doc "订阅某消息流的实时更新。"
  def subscribe(stream_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(stream_id))
  end

  defp topic(stream_id), do: "alert_stream:#{stream_id}"

  defp payload_msg_type(payload) do
    case payload["msg_type"] do
      "Alert" -> :alert
      "Update" -> :update
      "Cancel" -> :cancel
      _other -> :alert
    end
  end

  # 发布时刻的 sent 戳：东八区 ISO 8601（与初始消息格式一致）
  defp format_sent_now do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    shifted = DateTime.add(now, 8 * 3600, :second)
    Calendar.strftime(shifted, "%Y-%m-%dT%H:%M:%S+08:00")
  end

  defp now, do: DateTime.utc_now()

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
