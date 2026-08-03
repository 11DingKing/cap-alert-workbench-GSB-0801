defmodule CapAlertWorkbench.Cap do
  @moduledoc """
  Public application service / use-case boundary for the CAP alert workbench.

  LiveViews and API controllers call functions in this module only. They never
  directly manipulate status fields or Ecto schema state. All state transitions
  go through `CapAlertWorkbench.Cap.VersionStateMachine` via explicit pattern
  matching.
  """

  import Ecto.Query

  alias CapAlertWorkbench.Cap.{
    Alert,
    AreaCodes,
    AuditEvent,
    Enums,
    Info,
    Message,
    OutboxMessage,
    Review,
    Version,
    VersionDiff,
    VersionStateMachine
  }

  alias CapAlertWorkbench.Cap.Xml.Codec, as: XmlCodec

  alias CapAlertWorkbench.Repo
  alias Ecto.Multi

  @type result :: {:ok, map()} | {:error, term()}

  @doc """
  Creates a new alert thread with an initial draft payload.
  """
  @spec create_alert(map()) :: result()
  def create_alert(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    message = build_message(attrs)

    with {:ok, message} <- Message.validate(message),
         :ok <- AreaCodes.validate_codes(message.area_codes) do
      payload = message_to_map(message)

      %Alert{}
      |> Alert.changeset(%{
        identifier: message.identifier,
        sender: message.sender,
        draft_payload: payload,
        draft_lock_version: 1,
        draft_revision: 1,
        status: :draft,
        last_activity_at: now
      })
      |> Repo.insert()
      |> case do
        {:ok, alert} ->
          audit =
            build_audit(alert, :draft_created, attrs[:actor] || "system",
              summary: "Created initial draft",
              metadata: %{revision: 1}
            )

          Repo.insert!(audit)
          broadcast(alert, :alert_created)
          {:ok, %{alert: Repo.preload(alert, :versions)}}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Lists alert threads ordered by most recent activity.
  """
  def list_alerts do
    Alert
    |> order_by([a], desc: a.last_activity_at)
    |> Repo.all()
  end

  @doc """
  Fetches a single alert by identifier or id. Raises if not found.
  """
  def get_alert!(id_or_identifier) do
    id_or_identifier
    |> query_by_id_or_identifier()
    |> Repo.one!()
    |> Repo.preload([:versions, :reviews, :audit_events])
  end

  def fetch_alert(id_or_identifier) do
    case Repo.one(query_by_id_or_identifier(id_or_identifier)) do
      nil -> {:error, :not_found}
      alert -> {:ok, Repo.preload(alert, [:versions, :reviews, :audit_events])}
    end
  end

  defp query_by_id_or_identifier(value) do
    if valid_uuid?(value) do
      from a in Alert, where: a.id == ^value or a.identifier == ^value
    else
      from a in Alert, where: a.identifier == ^value
    end
  end

  defp valid_uuid?(value) when is_binary(value) do
    String.match?(value, ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i)
  end

  defp valid_uuid?(_), do: false

  @doc """
  Returns all versions for an alert, newest first.
  """
  def list_versions(alert_id) do
    Version
    |> where([v], v.alert_id == ^alert_id)
    |> order_by([v], desc: v.version_number)
    |> Repo.all()
  end

  @doc """
  Returns the audit trail for an alert, oldest first.
  """
  def list_audit_events(alert_id) do
    AuditEvent
    |> where([e], e.alert_id == ^alert_id)
    |> order_by([e], asc: e.occurred_at)
    |> Repo.all()
  end

  @doc """
  Builds a changeset for editing the working draft. The draft lock version is
  sent back with the form to detect concurrent edits.
  """
  def change_draft(alert, attrs \\ %{}) do
    payload = alert.draft_payload || %{}
    merged = Map.merge(payload, atomize_or_stringify(attrs))

    Alert.changeset(alert, %{
      draft_payload: merged,
      draft_lock_version: alert.draft_lock_version
    })
  end

  @doc """
  Updates the working draft using optimistic locking. If the supplied
  `expected_lock_version` does not match the current value, the update is
  rejected and the caller must reload before retrying.

  Every successful edit increments both the lock version and the content
  revision, which invalidates any in-flight review of an older revision.
  """
  @spec update_draft(String.t(), integer(), map(), String.t() | nil) :: result()
  def update_draft(alert_id, expected_lock_version, attrs, actor \\ nil) do
    with {:ok, alert} <- fetch_alert(alert_id) do
      do_update_draft(alert, expected_lock_version, attrs, actor)
    end
  end

  defp do_update_draft(alert, expected_lock_version, attrs, actor) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Multi.new()
    |> Multi.run(:lock, fn repo, _ ->
      locked =
        from(a in Alert,
          where: a.id == ^alert.id,
          lock: "FOR UPDATE"
        )
        |> repo.one!()

      # Verify optimistic lock AFTER acquiring the row lock so concurrent
      # transactions serialize and exactly one wins.
      if expected_lock_version in [nil, locked.draft_lock_version] do
        if VersionStateMachine.editable?(locked.status) do
          {:ok, locked}
        else
          {:error, {:draft_not_editable, locked.status}}
        end
      else
        {:error, {:lock_version_mismatch, locked.draft_lock_version, expected_lock_version}}
      end
    end)
    |> Multi.run(:validate, fn _repo, %{lock: locked} ->
      merged =
        locked.draft_payload
        |> map_to_message()
        |> merge_message(attrs)

      with {:ok, message} <- Message.validate(merged),
           :ok <- AreaCodes.validate_codes(message.area_codes) do
        {:ok, message}
      end
    end)
    |> Multi.run(:alert, fn repo, %{lock: locked, validate: message} ->
      new_lock = locked.draft_lock_version + 1
      new_revision = locked.draft_revision + 1

      new_status =
        case locked.status do
          :in_review -> :draft
          other -> other
        end

      locked
      |> Alert.changeset(%{
        draft_payload: message_to_map(message),
        draft_lock_version: new_lock,
        draft_revision: new_revision,
        status: new_status,
        last_activity_at: now
      })
      |> repo.update()
    end)
    |> Multi.run(:stale_reviews, fn repo, %{alert: updated} ->
      {count, _} =
        from(r in Review,
          where: r.alert_id == ^updated.id and r.stale == false,
          update: [set: [stale: true]]
        )
        |> repo.update_all([])

      {:ok, count}
    end)
    |> Multi.run(:audit, fn repo, %{alert: updated} ->
      event =
        build_audit(updated, :draft_updated, actor,
          summary: "Draft updated",
          metadata: %{
            revision: updated.draft_revision,
            lock_version: updated.draft_lock_version
          }
        )

      {:ok, repo.insert!(event)}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{alert: alert} = result} ->
        broadcast(alert, :draft_updated)
        {:ok, Map.put(result, :alert, Repo.preload(alert, [:versions, :reviews, :audit_events]))}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc """
  Applies a draft edit that was authored against a specific published base
  version.

  `expected_version` is the version number the author worked from. If the
  alert has since been corrected (e.g. C1 created version 2 while the editor
  was still on version 1), the edit is rejected with
  `{:error, :not_latest_version}` and no state is mutated. This prevents an
  old round-1 draft from overwriting round-2 area-level severities.

  The optimistic `expected_lock_version` check still applies on top of this
  base-version check, so concurrent editors on the same base version are
  serialised.
  """
  @spec submit_draft_based_on_version(
          String.t(),
          integer(),
          integer() | nil,
          map(),
          String.t() | nil
        ) :: result()
  def submit_draft_based_on_version(
        alert_id,
        expected_version,
        expected_lock_version,
        attrs,
        actor \\ nil
      ) do
    with {:ok, alert} <- fetch_alert(alert_id) do
      Multi.new()
      |> Multi.run(:alert_lock, fn repo, _ ->
        locked =
          from(a in Alert, where: a.id == ^alert.id, lock: "FOR UPDATE")
          |> repo.one!()

        cond do
          not is_nil(locked.latest_published_version) and
              expected_version != locked.latest_published_version ->
            {:error, {:not_latest_version, expected_version, locked.latest_published_version}}

          expected_lock_version not in [nil, locked.draft_lock_version] ->
            {:error, {:lock_version_mismatch, locked.draft_lock_version, expected_lock_version}}

          not VersionStateMachine.editable?(locked.status) ->
            {:error, {:draft_not_editable, locked.status}}

          true ->
            {:ok, locked}
        end
      end)
      |> Multi.run(:validate, fn _repo, %{alert_lock: locked} ->
        merged =
          locked.draft_payload
          |> map_to_message()
          |> merge_message(attrs)

        with {:ok, message} <- Message.validate(merged),
             :ok <- AreaCodes.validate_codes(message.area_codes) do
          {:ok, message}
        end
      end)
      |> Multi.run(:alert, fn repo, %{alert_lock: locked, validate: message} ->
        new_lock = locked.draft_lock_version + 1
        new_revision = locked.draft_revision + 1

        new_status =
          case locked.status do
            :in_review -> :draft
            other -> other
          end

        locked
        |> Alert.changeset(%{
          draft_payload: message_to_map(message),
          draft_lock_version: new_lock,
          draft_revision: new_revision,
          status: new_status,
          last_activity_at: utc_now()
        })
        |> repo.update()
      end)
      |> Multi.run(:stale_reviews, fn repo, %{alert: updated} ->
        {count, _} =
          from(r in Review,
            where: r.alert_id == ^updated.id and r.stale == false,
            update: [set: [stale: true]]
          )
          |> repo.update_all([])

        {:ok, count}
      end)
      |> Multi.run(:audit, fn repo, %{alert: updated} ->
        event =
          build_audit(updated, :draft_updated, actor,
            summary: "Draft updated (based on version #{expected_version})",
            metadata: %{
              revision: updated.draft_revision,
              lock_version: updated.draft_lock_version,
              base_version: expected_version
            }
          )

        {:ok, repo.insert!(event)}
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{alert: alert} = result} ->
          broadcast(alert, :draft_updated)

          {:ok,
           Map.put(result, :alert, Repo.preload(alert, [:versions, :reviews, :audit_events]))}

        {:error, :alert_lock, reason, _changes} ->
          maybe_record_stale_rejection(alert_id, expected_version, reason, actor)
          {:error, reason}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  defp maybe_record_stale_rejection(
         alert_id,
         expected_version,
         {:not_latest_version, _, latest},
         actor
       ) do
    with {:ok, alert} <- fetch_alert(alert_id) do
      event =
        build_audit(alert, :stale_draft_rejected, actor,
          summary:
            "Rejected draft based on stale version #{expected_version} (latest: #{latest})",
          metadata: %{base_version: expected_version, latest_version: latest}
        )

      Repo.insert!(event)
    end

    :ok
  end

  defp maybe_record_stale_rejection(_, _, _, _), do: :ok

  @doc """
  Submits the current draft for review. Creates a `:in_review` immutable
  version snapshot and an audit record.
  """
  @spec submit_for_review(String.t(), String.t() | nil) :: result()
  def submit_for_review(alert_id, actor \\ nil) do
    with {:ok, alert} <- fetch_alert(alert_id) do
      transition_and_snapshot(alert, :draft, :submit, :in_review,
        actor: actor,
        audit_action: :review_submitted,
        audit_summary: "Submitted for review",
        outbox_topic: "alert.review.submitted"
      )
    end
  end

  @doc """
  Records a review decision. The decision is rejected if it targets a revision
  older than the current draft (stale review racing with new edits).
  """
  @spec decide_review(String.t(), map(), String.t() | nil) :: result()
  def decide_review(alert_id, params, actor \\ nil) do
    decision =
      case params["decision"] || params[:decision] do
        "approved" -> :approved
        :approved -> :approved
        "changes_requested" -> :changes_requested
        :changes_requested -> :changes_requested
        "rejected" -> :rejected
        :rejected -> :rejected
      end

    comment = params["comment"] || params[:comment]

    Multi.new()
    |> Multi.run(:alert_lock, fn repo, _ ->
      alert =
        from(a in Alert, where: a.id == ^alert_id, lock: "FOR UPDATE")
        |> repo.one!()

      if alert.status != :in_review do
        {:error, {:invalid_status, alert.status}}
      else
        {:ok, alert}
      end
    end)
    |> Multi.run(:review_version, fn repo, %{alert_lock: alert} ->
      version =
        Version
        |> where([v], v.alert_id == ^alert.id and v.status == :in_review)
        |> order_by([v], desc: v.version_number)
        |> limit(1)
        |> repo.one()

      case version do
        nil -> {:error, :review_version_not_found}
        v -> {:ok, v}
      end
    end)
    |> Multi.run(:review, fn repo, %{alert_lock: alert, review_version: version} ->
      if version.revision_seed != alert.draft_revision do
        {:error, {:stale_review, version.revision_seed, alert.draft_revision}}
      else
        %Review{}
        |> Review.changeset(%{
          alert_id: alert.id,
          version_id: version.id,
          decision: decision,
          decision_revision: alert.draft_revision,
          reviewer: actor || params[:reviewer] || "reviewer",
          comment: comment,
          stale: false
        })
        |> repo.insert()
      end
    end)
    |> Multi.run(:transition, fn repo, %{alert_lock: alert, review_version: version} ->
      target =
        case decision do
          :approved -> :approved
          :changes_requested -> :rejected
          :rejected -> :rejected
        end

      event =
        case decision do
          :approved -> :approve
          :changes_requested -> :request_changes
          :rejected -> :reject
        end

      with {:ok, _} <- VersionStateMachine.transition(:in_review, event) do
        updated_alert =
          alert
          |> Alert.changeset(%{status: target, last_activity_at: utc_now()})
          |> repo.update!()

        updated_version =
          version
          |> Version.changeset(%{status: target, review_note: comment})
          |> repo.update!()

        {:ok, %{alert: updated_alert, version: updated_version}}
      end
    end)
    |> Multi.run(:audit, fn repo, %{transition: %{alert: alert}, review: review} ->
      event =
        build_audit(alert, :review_decision, actor,
          summary: "Review decision: #{decision}",
          metadata: %{
            decision: decision,
            comment: comment,
            revision: review.decision_revision
          }
        )

      {:ok, repo.insert!(event)}
    end)
    |> Multi.run(:outbox, fn repo, %{transition: %{alert: alert}} ->
      insert_outbox(repo, alert, "alert.review.#{decision}", %{
        alert_id: alert.id,
        identifier: alert.identifier,
        decision: decision
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{transition: %{alert: alert}} = result} ->
        preloaded = Repo.preload(alert, [:versions, :reviews, :audit_events])
        broadcast(preloaded, :review_decided)
        {:ok, Map.put(result, :alert, preloaded)}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc """
  Publishes the latest approved, non-stale version. Only the most recent
  approved version whose revision matches the current draft is publishable.
  Uses a database-level lock and idempotency checks to prevent duplicate
  publishing and transaction-mid-failure inconsistencies.
  """
  @spec publish(String.t(), String.t() | nil) :: result()
  def publish(alert_id, actor \\ nil) do
    Multi.new()
    |> Multi.run(:alert_lock, fn repo, _ ->
      alert =
        from(a in Alert, where: a.id == ^alert_id, lock: "FOR UPDATE")
        |> repo.one!()

      cond do
        alert.status == :published -> {:error, :already_published}
        alert.status != :approved -> {:error, {:not_publishable, alert.status}}
        true -> {:ok, alert}
      end
    end)
    |> Multi.run(:candidate, fn repo, %{alert_lock: alert} ->
      version =
        Version
        |> where([v], v.alert_id == ^alert.id and v.status == :approved)
        |> order_by([v], desc: v.version_number)
        |> limit(1)
        |> repo.one()

      cond do
        is_nil(version) ->
          {:error, :no_approved_version}

        version.revision_seed != alert.draft_revision ->
          {:error, :approved_version_is_stale}

        true ->
          {:ok, version}
      end
    end)
    |> Multi.run(:publish, fn repo, %{alert_lock: alert, candidate: version} ->
      with {:ok, next_status} <- VersionStateMachine.transition(:approved, :publish) do
        message = map_to_message(version.payload)
        xml = XmlCodec.encode!(message)

        published_version =
          version
          |> Version.changeset(%{
            status: next_status,
            xml_snapshot: xml,
            published_at: utc_now()
          })
          |> repo.update!()

        updated_alert =
          alert
          |> Alert.changeset(%{
            status: :published,
            published_identifier: message.identifier,
            latest_published_version: published_version.version_number,
            last_activity_at: utc_now()
          })
          |> repo.update!()

        {:ok, %{alert: updated_alert, version: published_version, xml: xml}}
      end
    end)
    |> Multi.run(:audit, fn repo, %{publish: %{alert: alert, version: version}} ->
      event =
        build_audit(alert, :published, actor,
          summary: "Published version #{version.version_number}",
          version: version,
          metadata: %{
            version_number: version.version_number,
            identifier: alert.published_identifier
          }
        )

      {:ok, repo.insert!(event)}
    end)
    |> Multi.run(:outbox, fn repo, %{publish: %{alert: alert, xml: xml, version: version}} ->
      insert_outbox(repo, alert, "alert.published", %{
        alert_id: alert.id,
        identifier: alert.published_identifier,
        version_number: version.version_number,
        xml: xml
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{publish: %{alert: alert}} = result} ->
        preloaded = Repo.preload(alert, [:versions, :reviews, :audit_events])
        broadcast(preloaded, :alert_published)
        {:ok, Map.put(result, :alert, preloaded)}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc """
  Creates a correction message based on the currently published version. The
  original published version becomes `:superseded`; a new draft is created and
  immediately published as a `:correction` kind version with msg_type `:update`.
  """
  @spec create_correction(String.t(), map(), String.t() | nil) :: result()
  def create_correction(alert_id, attrs, actor \\ nil) do
    create_follow_up(alert_id, attrs, actor, :correction, :update, [])
  end

  @doc """
  Issues the specific C1 correction `CN-20260729-GD-RAIN-001-C1` derived from
  the latest published version.

  Per the scenario: area `440800` stays at `Severe` while area `440900` is
  upgraded to `Extreme`. This requires two `<info>` segments in one CAP
  document. The correction's `references` point precisely at the first-round
  published document (root of the alert thread), not at any intermediate
  correction.

  The function derives strictly from the latest published version; concurrent
  publishes are serialised by `FOR UPDATE` so that only one C1 can be created.
  """
  @spec create_correction_c1(String.t(), String.t() | nil) :: result()
  def create_correction_c1(alert_id, actor \\ nil) do
    c1_identifier = "CN-20260729-GD-RAIN-001-C1"

    attrs = %{
      "identifier" => c1_identifier,
      "area_severities" => %{
        "440800" => :severe,
        "440900" => :extreme
      },
      "headline" => "广东省暴雨红色预警（更正 C1）：茂名升级为 Extreme",
      "description" => "更正：湛江市维持 Severe，茂名市升级为 Extreme。两地区分别通过独立的 info 段描述。",
      "instruction" => "茂名市按 Extreme 级别响应，湛江市按 Severe 级别响应。"
    }

    create_follow_up(alert_id, attrs, actor, :correction, :update,
      identifier: c1_identifier,
      precise_reference: :root
    )
  end

  @doc """
  Creates a cancellation message. The original published version becomes
  `:superseded`; a new `:canceled` version with msg_type `:cancel` is published.
  """
  @spec create_cancellation(String.t(), map(), String.t() | nil) :: result()
  def create_cancellation(alert_id, attrs, actor \\ nil) do
    create_follow_up(alert_id, attrs, actor, :cancellation, :cancel, [])
  end

  @doc """
  Issues the specific cancellation `CN-20260729-GD-RAIN-001-C2` derived from the
  currently published version (round 2 / C1).

  The cancellation:
    * references precisely the round-2 published C1 document (not the round-1
      root and not a chained reference list);
    * preserves the multi-info structure validated in round 3 — both areas keep
      their own `<info>` segment with their C1 severity, so the area-to-severity
      correspondence remains intact inside the cancellation document;
    * is idempotent: a repeated publish request returns the existing canceled
      version without inserting a second version, audit row or outbox message;
    * leaves the full version chain (1 -> 2 -> 3) queryable.

  Every state transition is recorded by the shared `create_follow_up/6`
  transaction (supersede of C1, insertion of C2, alert status -> canceled) with
  an audit event and a transactional outbox notification.
  """
  @spec create_cancellation_c2(String.t(), String.t() | nil) :: result()
  def create_cancellation_c2(alert_id, actor \\ nil) do
    c2_identifier = "CN-20260729-GD-RAIN-001-C2"

    attrs = %{
      "identifier" => c2_identifier,
      "headline" => "广东省暴雨预警解除（C2）",
      "description" => "本轮暴雨过程结束，湛江、茂名两地预警同步解除。解除消息保留 C1 验证过的多 info 结构。",
      "instruction" => "预警已解除，请恢复正常生产生活秩序，仍需注意次生灾害。",
      "note" => "预警解除 C2"
    }

    create_follow_up(alert_id, attrs, actor, :cancellation, :cancel,
      identifier: c2_identifier,
      precise_reference: :published,
      on_exists: :return_existing
    )
  end

  @doc "Diffs two versions by number. Returns `{:ok, changes}` or `:error`."
  def diff_versions(alert_id, version_a, version_b) do
    with {:ok, a} <- get_version(alert_id, version_a),
         {:ok, b} <- get_version(alert_id, version_b) do
      {:ok, VersionDiff.diff(a.payload, b.payload)}
    end
  end

  @doc "Returns the XML snapshot for a published version."
  def version_xml(alert_id, version_number) do
    case get_version(alert_id, version_number) do
      {:ok, version} -> {:ok, version.xml_snapshot}
      error -> error
    end
  end

  @doc "Imports a CAP XML string as a new alert thread."
  def import_xml(xml, actor \\ nil) when is_binary(xml) do
    with {:ok, message} <- XmlCodec.decode(xml),
         :ok <- AreaCodes.validate_codes(message.area_codes) do
      create_alert(%{
        identifier: message.identifier,
        sender: message.sender,
        sent_at: message.sent_at,
        status: message.status,
        msg_type: message.msg_type,
        scope: message.scope,
        language: message.language,
        urgency: message.urgency,
        severity: message.severity,
        certainty: message.certainty,
        event: message.event,
        headline: message.headline,
        description: message.description,
        instruction: message.instruction,
        area_codes: message.area_codes,
        note: message.note,
        references: message.references,
        extensions: message.extensions,
        actor: actor
      })
    end
  end

  @doc """
  Imports an external CAP XML document as a new alert thread and immediately
  places it into review.

  Unlike `import_xml/2`, which creates an editable draft, this creates an
  immutable `:in_review` version snapshot directly. Imported documents are
  never auto-published; a reviewer must approve and publish them. The XML
  (including special characters and unknown extension nodes) is preserved
  verbatim on the version as `xml_snapshot` so it round-trips exactly.
  """
  @spec import_xml_for_review(String.t(), String.t() | nil) :: result()
  def import_xml_for_review(xml, actor \\ nil) when is_binary(xml) do
    with {:ok, message} <- XmlCodec.decode(xml),
         :ok <- AreaCodes.validate_codes(message.area_codes) do
      payload = message_to_map(message)

      Multi.new()
      |> Multi.run(:alert, fn repo, _ ->
        %Alert{}
        |> Alert.changeset(%{
          identifier: message.identifier,
          sender: message.sender,
          draft_payload: payload,
          draft_lock_version: 1,
          draft_revision: 1,
          status: :in_review,
          last_activity_at: utc_now()
        })
        |> repo.insert()
      end)
      |> Multi.run(:version, fn repo, %{alert: alert} ->
        %Version{}
        |> Version.changeset(%{
          alert_id: alert.id,
          version_number: 1,
          status: :in_review,
          kind: :draft,
          payload: payload,
          xml_snapshot: XmlCodec.encode!(message),
          revision_seed: 1,
          created_by: actor
        })
        |> repo.insert()
      end)
      |> Multi.run(:audit, fn repo, %{alert: alert, version: version} ->
        event =
          build_audit(alert, :external_import, actor,
            summary: "Imported external message #{message.identifier} for review",
            version: version,
            metadata: %{identifier: message.identifier, source: :external_import}
          )

        {:ok, repo.insert!(event)}
      end)
      |> Multi.run(:outbox, fn repo, %{alert: alert} ->
        insert_outbox(repo, alert, "alert.review.submitted", %{
          alert_id: alert.id,
          identifier: alert.identifier,
          source: :external_import
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{alert: alert} = result} ->
          preloaded = Repo.preload(alert, [:versions, :reviews, :audit_events])
          broadcast(preloaded, :alert_imported)
          {:ok, Map.merge(result, %{alert: preloaded, message: message})}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  @doc "Encodes the current draft or a published version as CAP XML."
  def export_xml(alert, version_number \\ nil) do
    message =
      case version_number do
        nil ->
          map_to_message(alert.draft_payload)

        num ->
          case get_version(alert.id, num) do
            {:ok, version} -> map_to_message(version.payload)
            {:error, reason} -> throw({:error, reason})
          end
      end

    XmlCodec.encode!(message)
  end

  defp check_follow_up_status(alert) do
    if alert.status != :published do
      {:error, {:invalid_status, alert.status}}
    else
      {:ok, alert}
    end
  end

  defp create_follow_up(alert_id, attrs, actor, kind, msg_type, opts) do
    new_identifier = Keyword.get(opts, :identifier)
    precise_ref = Keyword.get(opts, :precise_reference)
    on_exists = Keyword.get(opts, :on_exists, :error)

    Multi.new()
    |> Multi.run(:alert_lock, fn repo, _ ->
      alert =
        from(a in Alert, where: a.id == ^alert_id, lock: "FOR UPDATE")
        |> repo.one!()

      cond do
        # Idempotent re-request: if the target version already exists and the
        # alert has reached the terminal state for this operation, return the
        # existing result without inserting another version, audit row or
        # outbox message.
        on_exists == :return_existing and is_binary(new_identifier) and
            alert.status in [:canceled, :published] ->
          existing =
            Version
            |> where([v], v.alert_id == ^alert.id)
            |> where([v], fragment("payload->>'identifier' = ?", ^new_identifier))
            |> order_by([v], asc: v.version_number)
            |> limit(1)
            |> repo.one()

          if existing do
            {:ok, %{idempotent: true, alert: alert, existing: existing}}
          else
            check_follow_up_status(alert)
          end

        true ->
          check_follow_up_status(alert)
      end
    end)
    |> Multi.run(:idempotency, fn repo, %{alert_lock: lock_result} ->
      case lock_result do
        %{idempotent: true} ->
          {:ok, :idempotent}

        %{} = alert ->
          # When a fixed identifier is supplied (e.g. C1), reject if a version
          # carrying that identifier already exists. Runs after the FOR UPDATE
          # row lock so concurrent transactions serialize and only one can win.
          if is_binary(new_identifier) do
            exists? =
              Version
              |> where([v], v.alert_id == ^alert.id)
              |> where([v], fragment("payload->>'identifier' = ?", ^new_identifier))
              |> repo.exists?()

            if exists? do
              if on_exists == :return_existing do
                {:ok, :exists}
              else
                {:error, {:already_exists, new_identifier}}
              end
            else
              {:ok, :not_found}
            end
          else
            {:ok, :not_applicable}
          end
      end
    end)
    |> Multi.run(:published, fn repo, %{alert_lock: lock_result, idempotency: idem} ->
      case {lock_result, idem} do
        {%{idempotent: true}, _} ->
          {:ok, nil}

        _ ->
          version =
            Version
            |> where([v], v.alert_id == ^lock_result.id and v.status == :published)
            |> order_by([v], desc: v.version_number)
            |> limit(1)
            |> repo.one()

          if version, do: {:ok, version}, else: {:error, :no_published_version}
      end
    end)
    |> Multi.run(:root_version, fn repo, %{alert_lock: lock_result} ->
      case lock_result do
        %{idempotent: true} ->
          {:ok, nil}

        _ ->
          version =
            Version
            |> where([v], v.alert_id == ^lock_result.id and v.kind == :draft)
            |> order_by([v], asc: v.version_number)
            |> limit(1)
            |> repo.one()

          {:ok, version}
      end
    end)
    |> Multi.run(:supersede, fn repo, %{alert_lock: lock_result, published: published} ->
      case lock_result do
        %{idempotent: true} ->
          {:ok, :skipped}

        _ ->
          new_id = Ecto.UUID.generate()

          superseded =
            published
            |> Version.changeset(%{status: :superseded, superseded_by: new_id})
            |> repo.update!()

          {:ok, %{version: superseded, new_id: new_id}}
      end
    end)
    |> Multi.run(:new_version, fn repo,
                                  %{
                                    alert_lock: lock_result,
                                    published: published,
                                    root_version: root_version,
                                    supersede: supersede
                                  } ->
      case lock_result do
        %{idempotent: true, existing: existing} ->
          {:ok,
           %{
             version: existing,
             alert: lock_result.alert,
             xml: existing.xml_snapshot,
             idempotent: true
           }}

        _ ->
          %{new_id: new_id} = supersede
          alert = lock_result
          next_number = published.version_number + 1

          base_message =
            published.payload
            |> map_to_message()
            |> merge_message(attrs)

          references =
            case precise_ref do
              :root when not is_nil(root_version) ->
                [build_version_reference(root_version)]

              :published ->
                [build_version_reference(published)]

              _ ->
                build_references(alert, published, msg_type)
            end

          base_message =
            base_message
            |> Map.put(:msg_type, msg_type)
            |> Map.put(:references, references)
            |> maybe_put_identifier(new_identifier)

          message =
            case kind do
              :cancellation ->
                %{base_message | note: attrs["note"] || attrs[:note] || "预警解除"}

              :correction ->
                base_message
            end

          with {:ok, message} <- Message.validate(message),
               :ok <- AreaCodes.validate_codes(Message.area_codes(message)) do
            xml = XmlCodec.encode!(message)

            new_status = if kind == :cancellation, do: :canceled, else: :published

            version =
              %Version{id: new_id}
              |> Version.changeset(%{
                alert_id: alert.id,
                version_number: next_number,
                status: new_status,
                kind: kind,
                payload: message_to_map(message),
                xml_snapshot: xml,
                references: message.references,
                created_by: actor,
                published_at: utc_now(),
                revision_seed: alert.draft_revision
              })
              |> repo.insert!()

            alert_status = if kind == :cancellation, do: :canceled, else: :published

            updated_alert =
              alert
              |> Alert.changeset(%{
                status: alert_status,
                latest_published_version: next_number,
                last_activity_at: utc_now()
              })
              |> repo.update!()

            {:ok, %{version: version, alert: updated_alert, xml: xml}}
          else
            {:error, reason} -> {:error, reason}
          end
      end
    end)
    |> Multi.run(:audit, fn repo, %{alert_lock: lock_result, new_version: new_version} ->
      case new_version do
        %{idempotent: true} ->
          {:ok, :skipped}

        _ ->
          action = if kind == :cancellation, do: :cancellation_created, else: :correction_created

          event =
            build_audit(lock_result, action, actor,
              summary: "#{kind} version #{new_version.version.version_number}",
              version: new_version.version,
              metadata: %{version_number: new_version.version.version_number}
            )

          {:ok, repo.insert!(event)}
      end
    end)
    |> Multi.run(:outbox, fn repo, %{alert_lock: lock_result, new_version: new_version} ->
      case new_version do
        %{idempotent: true} ->
          {:ok, :skipped}

        _ ->
          topic = if kind == :cancellation, do: "alert.canceled", else: "alert.corrected"

          insert_outbox(repo, lock_result, topic, %{
            alert_id: lock_result.id,
            version_number: new_version.version.version_number,
            xml: new_version.xml
          })
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{new_version: %{idempotent: true, version: version, alert: alert}} = result} ->
        preloaded = Repo.preload(alert, [:versions, :reviews, :audit_events])

        {:ok,
         result
         |> Map.put(:alert, preloaded)
         |> Map.put(:version, version)
         |> Map.put(:idempotent, true)}

      {:ok, %{new_version: %{alert: alert}} = result} ->
        preloaded = Repo.preload(alert, [:versions, :reviews, :audit_events])
        broadcast(preloaded, String.to_atom("alert_#{kind}"))
        {:ok, Map.put(result, :alert, preloaded)}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp transition_and_snapshot(alert, from_state, event, to_state, opts) do
    actor = opts[:actor]

    Multi.new()
    |> Multi.run(:alert_lock, fn repo, _ ->
      locked =
        from(a in Alert, where: a.id == ^alert.id, lock: "FOR UPDATE")
        |> repo.one!()

      if locked.status != from_state do
        {:error, {:invalid_status, locked.status}}
      else
        {:ok, locked}
      end
    end)
    |> Multi.run(:transition, fn _repo, %{alert_lock: locked} ->
      VersionStateMachine.transition(locked.status, event)
    end)
    |> Multi.run(:version, fn repo, %{alert_lock: locked, transition: next_status} ->
      max_number =
        from(v in Version,
          where: v.alert_id == ^locked.id,
          select: coalesce(max(v.version_number), 0)
        )
        |> repo.one()

      message = map_to_message(locked.draft_payload)
      xml_snapshot = if to_state == :published, do: XmlCodec.encode!(message), else: nil

      %Version{}
      |> Version.changeset(%{
        alert_id: locked.id,
        version_number: max_number + 1,
        status: next_status,
        kind: :draft,
        payload: locked.draft_payload,
        xml_snapshot: xml_snapshot,
        revision_seed: locked.draft_revision,
        created_by: actor
      })
      |> repo.insert()
    end)
    |> Multi.run(:alert, fn repo,
                            %{alert_lock: locked, transition: next_status, version: version} ->
      locked
      |> Alert.changeset(%{status: next_status, last_activity_at: utc_now()})
      |> repo.update()
      |> case do
        {:ok, alert} -> {:ok, %{alert: alert, version: version}}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> Multi.run(:audit, fn repo, %{alert: %{alert: alert, version: version}} ->
      event =
        build_audit(alert, opts[:audit_action], actor,
          summary: opts[:audit_summary],
          version: version,
          metadata: %{to_status: to_state, revision: alert.draft_revision}
        )

      {:ok, repo.insert!(event)}
    end)
    |> Multi.run(:outbox, fn repo, %{alert: %{alert: alert}} ->
      insert_outbox(repo, alert, opts[:outbox_topic], %{
        alert_id: alert.id,
        identifier: alert.identifier
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{alert: %{alert: alert}} = result} ->
        preloaded = Repo.preload(alert, [:versions, :reviews, :audit_events])
        broadcast(preloaded, :status_changed)
        {:ok, Map.put(result, :alert, preloaded)}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp get_version(alert_id, version_number) when is_integer(version_number) do
    case Repo.one(
           from v in Version,
             where: v.alert_id == ^alert_id and v.version_number == ^version_number
         ) do
      nil -> {:error, :not_found}
      v -> {:ok, v}
    end
  end

  defp get_version(alert_id, version_number) when is_binary(version_number) do
    case Integer.parse(version_number) do
      {num, ""} -> get_version(alert_id, num)
      _ -> {:error, :invalid_version_number}
    end
  end

  defp build_references(alert, published, msg_type) do
    base = published.payload["references"] || []

    sent =
      case published.payload["sent_at"] do
        %DateTime{} = dt ->
          XmlCodec.format_ref_time(dt)

        %{} = dt_map ->
          with {:ok, dt, _} <- DateTime.from_iso8601(dt_map) do
            XmlCodec.format_ref_time(dt)
          else
            _ -> ""
          end

        text when is_binary(text) ->
          case DateTime.from_iso8601(text) do
            {:ok, dt, _} -> XmlCodec.format_ref_time(dt)
            _ -> text
          end

        nil ->
          ""
      end

    new_ref =
      "#{alert.sender},#{published.payload["identifier"]},#{sent}"

    case msg_type do
      :update -> Enum.uniq(base ++ [new_ref])
      :cancel -> Enum.uniq(base ++ [new_ref])
      _ -> base
    end
  end

  # Builds a CAP references string that points precisely at one published
  # version (used by C1 to reference the first-round document only).
  defp build_version_reference(version) do
    payload = version.payload
    sent = payload["sent_at"]

    sent_text =
      cond do
        is_struct(sent, DateTime) ->
          XmlCodec.format_ref_time(sent)

        is_binary(sent) ->
          case DateTime.from_iso8601(sent) do
            {:ok, dt, _} -> XmlCodec.format_ref_time(dt)
            _ -> sent
          end

        is_map(sent) and not is_struct(sent) ->
          with {:ok, dt, _} <- DateTime.from_iso8601(sent) do
            XmlCodec.format_ref_time(dt)
          else
            _ -> ""
          end

        true ->
          ""
      end

    sender = payload["sender"]
    identifier = payload["identifier"]
    "#{sender},#{identifier},#{sent_text}"
  end

  defp maybe_put_identifier(message, nil), do: message
  defp maybe_put_identifier(message, identifier), do: %{message | identifier: identifier}

  defp build_audit(alert, action, actor, opts) do
    %AuditEvent{
      alert_id: alert.id,
      version_id: opts[:version] && opts[:version].id,
      action: Enums.audit_action_to_string(action),
      actor: actor || "system",
      summary: opts[:summary],
      metadata: opts[:metadata] || %{},
      occurred_at: utc_now()
    }
  end

  defp insert_outbox(repo, alert, topic, payload) do
    %OutboxMessage{}
    |> OutboxMessage.changeset(%{
      alert_id: alert.id,
      topic: topic,
      payload: payload,
      status: :pending,
      available_at: utc_now()
    })
    |> repo.insert()
  end

  defp build_message(attrs) do
    message = XmlCodec.seed_message([])

    message =
      Enum.reduce(attrs, message, fn
        {:identifier, v}, acc -> %{acc | identifier: v}
        {:sender, v}, acc -> %{acc | sender: v}
        {:sent_at, v}, acc -> %{acc | sent_at: to_datetime(v)}
        {:status, v}, acc -> %{acc | status: cast_enum(v, &Enums.cast_status/1)}
        {:msg_type, v}, acc -> %{acc | msg_type: cast_enum(v, &Enums.cast_msg_type/1)}
        {:scope, v}, acc -> %{acc | scope: cast_enum(v, &Enums.cast_scope/1)}
        {:language, v}, acc -> %{acc | language: v}
        {:urgency, v}, acc -> %{acc | urgency: cast_enum(v, &Enums.cast_urgency/1)}
        {:severity, v}, acc -> %{acc | severity: cast_enum(v, &Enums.cast_severity/1)}
        {:certainty, v}, acc -> %{acc | certainty: cast_enum(v, &Enums.cast_certainty/1)}
        {:event, v}, acc -> %{acc | event: v}
        {:headline, v}, acc -> %{acc | headline: v}
        {:description, v}, acc -> %{acc | description: v}
        {:instruction, v}, acc -> %{acc | instruction: v}
        {:note, v}, acc -> %{acc | note: v}
        {:area_codes, v}, acc -> put_area_codes(acc, List.wrap(v))
        {:references, v}, acc -> %{acc | references: List.wrap(v)}
        {:extensions, v}, acc -> %{acc | extensions: List.wrap(v)}
        {:infos, v}, acc when is_list(v) -> %{acc | infos: Enum.map(v, &info_from_map/1)}
        _, acc -> acc
      end)

    sync_message_fields(message)
  end

  defp put_area_codes(message, []), do: message

  defp put_area_codes(message, codes) do
    areas =
      Enum.map(codes, fn code ->
        %{code: code, description: AreaCodes.description(code) || code}
      end)

    infos =
      case message.infos do
        [first | rest] ->
          [%{first | areas: areas} | rest]

        [] ->
          [
            %Info{
              language: message.language || "zh-CN",
              event: message.event,
              urgency: message.urgency,
              severity: message.severity,
              certainty: message.certainty,
              headline: message.headline,
              description: message.description,
              instruction: message.instruction,
              areas: areas
            }
          ]
      end

    %{message | infos: infos}
  end

  defp merge_message(message, attrs) when is_map(attrs) do
    string_attrs = for {k, v} <- attrs, into: %{}, do: {to_string(k), v}

    message =
      Enum.reduce(string_attrs, message, fn
        {"event", v}, acc ->
          update_all_infos(acc, fn info -> %{info | event: v} end)

        {"headline", v}, acc ->
          update_all_infos(acc, fn info -> %{info | headline: v} end)

        {"description", v}, acc ->
          update_all_infos(acc, fn info -> %{info | description: v} end)

        {"instruction", v}, acc ->
          update_all_infos(acc, fn info -> %{info | instruction: v} end)

        {"note", v}, acc ->
          %{acc | note: v}

        {"urgency", v}, acc ->
          update_all_infos(acc, fn info ->
            %{info | urgency: cast_enum(v, &Enums.cast_urgency/1)}
          end)

        {"severity", v}, acc ->
          update_all_infos(acc, fn info ->
            %{info | severity: cast_enum(v, &Enums.cast_severity/1)}
          end)

        {"certainty", v}, acc ->
          update_all_infos(acc, fn info ->
            %{info | certainty: cast_enum(v, &Enums.cast_certainty/1)}
          end)

        {"scope", v}, acc ->
          %{acc | scope: cast_enum(v, &Enums.cast_scope/1)}

        {"status", v}, acc ->
          %{acc | status: cast_enum(v, &Enums.cast_status/1)}

        {"infos", v}, acc when is_list(v) ->
          %{acc | infos: Enum.map(v, &info_from_map/1)}

        {"area_severities", v}, acc when is_map(v) ->
          apply_area_severities(acc, v)

        _, acc ->
          acc
      end)

    sync_message_fields(message)
  end

  # Applies a severity override per area code, e.g. %{"440900" => :extreme}.
  # Existing info segments that contain a matching area are split so that the
  # matched area gets its own segment with the new severity.
  defp apply_area_severities(message, area_severities) do
    infos =
      Enum.flat_map(message.infos, fn info ->
        {matched, rest} =
          Enum.split_with(info.areas, fn area ->
            Map.has_key?(area_severities, area.code)
          end)

        rest_infos =
          if rest == [] do
            []
          else
            [%{info | areas: rest}]
          end

        matched_infos =
          Enum.map(matched, fn area ->
            %{
              info
              | areas: [area],
                severity:
                  cast_enum(
                    Map.get(area_severities, area.code),
                    &Enums.cast_severity/1
                  )
            }
          end)

        rest_infos ++ matched_infos
      end)

    %{message | infos: infos}
  end

  defp update_all_infos(message, fun) do
    %{message | infos: Enum.map(message.infos, fun)}
  end

  # Keep the top-level convenience fields in sync with the first info segment
  # after a merge, so callers that read message.severity etc. see the default.
  defp sync_message_fields(message) do
    message =
      case message.infos do
        [first | _] ->
          %{
            message
            | language: first.language,
              urgency: first.urgency,
              severity: first.severity,
              certainty: first.certainty,
              event: first.event,
              headline: first.headline,
              description: first.description,
              instruction: first.instruction
          }

        [] ->
          message
      end

    %{
      message
      | area_codes: Message.area_codes(message),
        area_descriptions: Message.area_descriptions(message)
    }
  end

  defp cast_enum(value, caster) when is_binary(value) do
    case caster.(value) do
      {:ok, atom} -> atom
      :error -> value
    end
  end

  defp cast_enum(value, _caster), do: value

  defp message_to_map(%Message{} = message) do
    %{
      "identifier" => message.identifier,
      "sender" => message.sender,
      "sent_at" => message.sent_at,
      "status" => Atom.to_string(message.status),
      "msg_type" => Atom.to_string(message.msg_type),
      "scope" => Atom.to_string(message.scope),
      "language" => message.language,
      "urgency" => Atom.to_string(message.urgency),
      "severity" => Atom.to_string(message.severity),
      "certainty" => Atom.to_string(message.certainty),
      "event" => message.event,
      "headline" => message.headline,
      "description" => message.description,
      "instruction" => message.instruction,
      "note" => message.note,
      "infos" => Enum.map(message.infos, &info_to_map/1),
      "area_codes" => Message.area_codes(message),
      "area_descriptions" => Message.area_descriptions(message),
      "references" => message.references,
      "extensions" => encode_extensions(message.extensions)
    }
  end

  defp info_to_map(%Info{} = info) do
    %{
      "language" => info.language,
      "event" => info.event,
      "urgency" => Atom.to_string(info.urgency),
      "severity" => Atom.to_string(info.severity),
      "certainty" => Atom.to_string(info.certainty),
      "headline" => info.headline,
      "description" => info.description,
      "instruction" => info.instruction,
      "category" => info.category,
      "areas" =>
        Enum.map(info.areas, fn area ->
          %{"code" => area.code, "description" => area.description}
        end),
      "extensions" => encode_extensions(info.extensions)
    }
  end

  defp info_from_map(%Info{} = info), do: info

  defp info_from_map(map) when is_map(map) do
    %Info{
      language: map["language"] || map[:language] || "zh-CN",
      event: map["event"] || map[:event],
      urgency: atomize(map["urgency"] || map[:urgency], Enums.urgencies()),
      severity: atomize(map["severity"] || map[:severity], Enums.severities()),
      certainty: atomize(map["certainty"] || map[:certainty], Enums.certainties()),
      headline: map["headline"] || map[:headline],
      description: map["description"] || map[:description],
      instruction: map["instruction"] || map[:instruction],
      category: map["category"] || map[:category] || "Met",
      areas: parse_areas(map["areas"] || map[:areas] || []),
      extensions: decode_extensions(map["extensions"] || map[:extensions] || [])
    }
  end

  defp parse_areas(areas) when is_list(areas) do
    Enum.map(areas, fn
      %{"code" => code, "description" => desc} -> %{code: code, description: desc}
      %{code: code, description: desc} -> %{code: code, description: desc}
      code when is_binary(code) -> %{code: code, description: AreaCodes.description(code) || code}
    end)
  end

  defp parse_areas(_), do: []

  defp map_to_message(%Message{} = m), do: m

  defp map_to_message(payload) when is_map(payload) do
    infos =
      case payload["infos"] do
        [_ | _] = infos ->
          Enum.map(infos, &info_from_map/1)

        _ ->
          # Legacy payload without infos; reconstruct a single info segment
          # from the top-level fields and area_codes.
          [reconstruct_info(payload)]
      end

    first = List.first(infos)

    %Message{
      identifier: payload["identifier"],
      sender: payload["sender"],
      sent_at: to_datetime(payload["sent_at"]),
      status: atomize(payload["status"], Enums.statuses()),
      msg_type: atomize(payload["msg_type"], Enums.msg_types()),
      scope: atomize(payload["scope"], Enums.scopes()),
      language: first && first.language,
      urgency: first && first.urgency,
      severity: first && first.severity,
      certainty: first && first.certainty,
      event: first && first.event,
      headline: first && first.headline,
      description: first && first.description,
      instruction: first && first.instruction,
      note: payload["note"],
      references: payload["references"] || [],
      extensions: decode_extensions(payload["extensions"]),
      infos: infos,
      area_codes: payload["area_codes"] || Enum.flat_map(infos, &Info.area_codes/1),
      area_descriptions:
        payload["area_descriptions"] || Enum.flat_map(infos, &Info.area_descriptions/1)
    }
  end

  defp reconstruct_info(payload) do
    codes = payload["area_codes"] || []
    descs = payload["area_descriptions"] || []

    areas =
      codes
      |> Enum.zip(descs)
      |> Enum.map(fn {code, desc} ->
        %{code: code, description: desc || AreaCodes.description(code) || code}
      end)

    %Info{
      language: payload["language"] || "zh-CN",
      event: payload["event"],
      urgency: atomize(payload["urgency"], Enums.urgencies()),
      severity: atomize(payload["severity"], Enums.severities()),
      certainty: atomize(payload["certainty"], Enums.certainties()),
      headline: payload["headline"],
      description: payload["description"],
      instruction: payload["instruction"],
      areas: areas
    }
  end

  defp encode_extensions(nil), do: []
  defp encode_extensions(exts) when is_list(exts), do: Enum.map(exts, &encode_extension/1)

  # Full node-tree maps are JSON-serialisable as-is (preserving nested trees).
  defp encode_extension(%{"name" => _} = node), do: node
  defp encode_extension(%{name: _} = node), do: node

  # Legacy tuple forms.
  defp encode_extension({name, attrs, value}), do: [name, attrs, value]
  defp encode_extension([name, attrs, value]), do: [name, attrs, value]

  defp decode_extensions(nil), do: []

  defp decode_extensions(exts) when is_list(exts) do
    Enum.map(exts, &decode_extension/1)
  end

  defp decode_extensions(_), do: []

  defp decode_extension(%{"name" => name} = node) do
    %{
      name: name,
      ns: node["ns"] || "",
      attrs: atom_keys_to_string(node["attrs"] || %{}),
      children: decode_extension_children(node["children"] || [])
    }
  end

  defp decode_extension(%{name: name} = node) do
    %{
      name: name,
      ns: node[:ns] || "",
      attrs: atom_keys_to_string(node[:attrs] || %{}),
      children: decode_extension_children(node[:children] || [])
    }
  end

  defp decode_extension([name, attrs, value]), do: {name, attrs, value}
  defp decode_extension(other), do: other

  defp decode_extension_children(children) when is_list(children) do
    Enum.map(children, fn
      %{"name" => _} = child -> decode_extension(child)
      %{name: _} = child -> decode_extension(child)
      text when is_binary(text) -> text
      other -> to_string(other)
    end)
  end

  defp decode_extension_children(_), do: []

  defp atom_keys_to_string(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp atom_keys_to_string(other), do: other

  defp atomize(value, allowed) when is_binary(value) do
    atom = String.to_existing_atom(value)
    if atom in allowed, do: atom, else: String.to_atom(value)
  rescue
    ArgumentError -> String.to_atom(value)
  end

  defp atomize(value, _allowed), do: value

  defp to_datetime(%DateTime{} = dt), do: dt

  defp to_datetime(%{} = dt) do
    {:ok, datetime, _} = DateTime.from_iso8601(dt)
    datetime
  end

  defp to_datetime(nil), do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp to_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now() |> DateTime.truncate(:second)
    end
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp atomize_or_stringify(attrs) do
    for {k, v} <- attrs, into: %{} do
      {to_string(k), v}
    end
  end

  defp broadcast(alert, event) do
    Phoenix.PubSub.broadcast(
      CapAlertWorkbench.PubSub,
      "alert:#{alert.id}",
      {event, alert}
    )

    Phoenix.PubSub.broadcast(
      CapAlertWorkbench.PubSub,
      "alerts",
      {event, alert}
    )

    :ok
  end

  @doc false
  def subscribe(alert_id),
    do: Phoenix.PubSub.subscribe(CapAlertWorkbench.PubSub, "alert:#{alert_id}")

  def subscribe_all, do: Phoenix.PubSub.subscribe(CapAlertWorkbench.PubSub, "alerts")
end
