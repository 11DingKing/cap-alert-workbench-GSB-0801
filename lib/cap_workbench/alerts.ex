defmodule CapWorkbench.Alerts do
  @moduledoc """
  Public application/service layer for the CAP alert editing workbench.

  This is the ONLY sanctioned entry point for changing alert workflow state.
  LiveViews and controllers call these use-cases; they never touch
  `workflow_state`, `review_state`, `published`, `lock_version`, or the outbox
  directly, and they never talk to `Repo` for state changes.

  Guarantees enforced here:

    * Every content edit produces a NEW immutable `DraftVersion`; existing
      versions are never mutated.
    * Concurrent edits to the same message are serialized with an optimistic
      lock on `AlertMessage.lock_version`; a losing writer gets `{:error, :stale}`.
    * A review decision only applies to the version actually under review; if a
      newer draft has superseded it, the stale decision is rejected.
    * Only the latest, approved version may be published, exactly once. Publish,
      audit-event insertion, and outbox enqueue happen in a single transaction;
      a failure anywhere rolls the whole thing back, keeping page state,
      immutable versions, audit trail, and outbox consistent.
    * Published content is frozen. Changes are expressed only as correction
      (`:update`) or cancellation (`:cancel`) messages that reference the
      published one; publishing such a message supersedes its predecessor.
  """

  import Ecto.Query

  alias CapWorkbench.Repo

  alias CapWorkbench.Cap.{
    AlertMessage,
    AuditEvent,
    DraftVersion,
    Enums,
    OutboxEntry,
    StateMachine,
    Xml
  }

  alias Ecto.Multi

  @default_sender "cap@gd.gov.cn"

  @pubsub CapWorkbench.PubSub

  # --- PubSub: keep concurrent viewers of a message in sync ------------------

  @doc "Subscribes the calling process to change events for a message id."
  def subscribe(message_id) when is_binary(message_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(message_id))
  end

  @doc "Subscribes to the message list topic (new messages)."
  def subscribe_all do
    Phoenix.PubSub.subscribe(@pubsub, "messages")
  end

  defp broadcast(message_id, event) when is_binary(message_id) do
    # broadcast_from/4 excludes the calling process, so the LiveView that
    # performed the action (and already reloads locally) does not receive its
    # own event as a spurious "changed elsewhere" notification. Other viewers do.
    Phoenix.PubSub.broadcast_from(
      @pubsub,
      self(),
      topic(message_id),
      {:alert_updated, message_id, event}
    )

    Phoenix.PubSub.broadcast_from(
      @pubsub,
      self(),
      "messages",
      {:messages_changed, message_id, event}
    )

    :ok
  end

  defp topic(message_id), do: "message:" <> message_id

  # --- Queries ---------------------------------------------------------------

  @doc "Lists alert messages, newest first, with their versions preloaded."
  def list_messages do
    AlertMessage
    |> order_by(desc: :inserted_at)
    |> Repo.all()
    |> Repo.preload(versions: version_order())
  end

  @doc "Fetches a message with versions preloaded, or nil."
  def get_message(id) do
    AlertMessage
    |> Repo.get(id)
    |> case do
      nil -> nil
      message -> Repo.preload(message, versions: version_order())
    end
  end

  @doc "Fetches a message with versions preloaded, raising if not found."
  def get_message!(id) do
    AlertMessage
    |> Repo.get!(id)
    |> Repo.preload(versions: version_order())
  end

  @doc "Returns the version with the highest version number for a message."
  def latest_version(%AlertMessage{} = message) do
    message = Repo.preload(message, versions: version_order())
    List.last(message.versions)
  end

  @doc "Fetches a single version by id."
  def get_version!(id), do: Repo.get!(DraftVersion, id)

  @doc "Lists audit events for a message, oldest first."
  def list_audit_events(%AlertMessage{id: id}) do
    AuditEvent
    |> where(alert_message_id: ^id)
    |> order_by(asc: :occurred_at)
    |> Repo.all()
  end

  @doc "Lists outbox entries for a message, newest first."
  def list_outbox_entries(%AlertMessage{id: id}) do
    OutboxEntry
    |> where(alert_message_id: ^id)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  defp version_order, do: from(v in DraftVersion, order_by: [asc: v.version_number])

  # --- Use case: create a brand new draft message ----------------------------

  @doc """
  Creates a new alert message with its first immutable draft version.

  `attrs` carries both envelope identity (identifier/sender/sent/status/etc.)
  and the first version's content. Returns `{:ok, message}` or
  `{:error, changeset}`.
  """
  def create_message(attrs, actor \\ "system") do
    message_attrs = Map.take(attrs, ~w(identifier sender sent_at status msg_type scope
                                       references_text references_message_id)a)

    Multi.new()
    |> Multi.insert(:message, AlertMessage.create_changeset(%AlertMessage{}, message_attrs))
    |> Multi.insert(:version, fn %{message: message} ->
      DraftVersion.content_changeset(%DraftVersion{}, attrs, %{
        version_number: 1,
        alert_message_id: message.id,
        created_by: actor
      })
    end)
    |> Multi.insert(:audit, fn %{message: message, version: version} ->
      audit(message, version, :draft_created, actor, nil, "drafting")
    end)
    |> transact()
    |> normalize_multi(:message)
    |> notify(:created)
  end

  # --- Use case: save a new immutable draft version (edit) -------------------

  @doc """
  Saves an edit as a NEW immutable version.

  `expected_lock_version` is the aggregate lock the editor loaded with. If a
  concurrent editor has since written, this returns `{:error, :stale}` and the
  caller must reload. On success the message returns to `:drafting` (any prior
  review is invalidated because a new version now leads).
  """
  def save_new_version(%AlertMessage{} = message, attrs, expected_lock_version, actor \\ "system") do
    with :ok <- ensure_editable(message) do
      # A new version carries forward the latest version's content, overlaid
      # with the caller's edits. This keeps unedited fields intact while still
      # producing a fresh immutable snapshot.
      base = base_content(message)
      merged = Map.merge(base, stringify_keys(attrs))

      Multi.new()
      |> lock_message(message, expected_lock_version, :save_version)
      |> Multi.insert(:version, fn %{message: locked} ->
        DraftVersion.content_changeset(%DraftVersion{}, merged, %{
          version_number: next_version_number(locked),
          alert_message_id: locked.id,
          created_by: actor
        })
      end)
      |> Multi.insert(:audit, fn %{message: locked, version: version} ->
        audit(
          locked,
          version,
          :version_saved,
          actor,
          to_string(message.workflow_state),
          "drafting"
        )
      end)
      |> transact()
      |> normalize_multi(:message)
      |> notify(:version_saved)
    end
  end

  # --- Use case: submit latest version for review ----------------------------

  @doc """
  Submits the given version for review.

  Guarded by the state machine: only the latest, non-approved/non-published
  version of a `:drafting` message may be submitted. Optimistically locked.
  """
  def submit_for_review(
        %AlertMessage{} = message,
        %DraftVersion{} = version,
        expected_lock_version,
        actor \\ "system"
      ) do
    with :ok <- ensure_latest(message, version),
         true <- StateMachine.can_submit?(message, version) || {:error, :not_submittable} do
      Multi.new()
      |> lock_message(message, expected_lock_version, :submit_for_review)
      |> Multi.update(
        :version,
        DraftVersion.review_transition(version, %{review_state: :in_review})
      )
      |> Multi.insert(:audit, fn %{message: locked} ->
        audit(locked, version, :submitted_for_review, actor, "drafting", "in_review")
      end)
      |> transact()
      |> normalize_multi(:message)
      |> notify(:submitted)
    else
      {:error, _} = error -> error
    end
  end

  # --- Use case: record a review decision ------------------------------------

  @doc """
  Records an approve/reject decision for the version under review.

  Rejects stale decisions: if a newer draft has been saved (so this version is
  no longer the one in review, or the message is no longer `:in_review`), the
  decision is refused with `{:error, :stale_review}`.
  """
  def review(message, version, decision, reviewer, comment \\ nil, expected_lock_version)

  def review(
        %AlertMessage{} = message,
        %DraftVersion{} = version,
        decision,
        reviewer,
        comment,
        expected_lock_version
      )
      when decision in [:approve, :reject] do
    # Re-read inside the caller to defend against a stale in-memory version.
    fresh_version = get_version!(version.id)

    cond do
      not StateMachine.can_review?(message, fresh_version) ->
        {:error, :stale_review}

      not is_latest?(message, fresh_version) ->
        {:error, :stale_review}

      true ->
        {event, review_state, to_state} =
          case decision do
            :approve -> {:approve, :approved, "in_review"}
            :reject -> {:reject, :rejected, "drafting"}
          end

        Multi.new()
        |> lock_message(message, expected_lock_version, event)
        |> Multi.update(:version, fn _ ->
          DraftVersion.review_transition(fresh_version, %{
            review_state: review_state,
            reviewed_by: reviewer,
            reviewed_at: DateTime.utc_now(),
            review_comment: comment
          })
        end)
        |> Multi.insert(:audit, fn %{message: locked} ->
          audit(locked, fresh_version, review_action(decision), reviewer, "in_review", to_state)
        end)
        |> transact()
        |> normalize_multi(:message)
        |> notify({:reviewed, decision})
    end
  end

  defp review_action(:approve), do: :approved
  defp review_action(:reject), do: :rejected

  # --- Use case: publish -----------------------------------------------------

  @doc """
  Publishes the given approved version.

  Only the latest, approved, not-yet-published version of an `:in_review`
  message may publish, and only once. The version is frozen, the message moves
  to `:published`, an audit event is recorded, and an outbox entry is enqueued —
  all in one transaction. A duplicate/racing publish is rejected via the
  outbox `dedupe_key` unique index (`{:error, :duplicate_publish}`).

  If the message is a correction/cancellation, its referenced predecessor is
  atomically superseded in the same transaction.
  """
  def publish(
        %AlertMessage{} = message,
        %DraftVersion{} = version,
        expected_lock_version,
        actor \\ "system"
      ) do
    fresh_version = get_version!(version.id)

    cond do
      message.workflow_state == :published ->
        {:error, :already_published}

      not StateMachine.can_publish?(message, fresh_version) ->
        {:error, :not_publishable}

      not is_latest?(message, fresh_version) ->
        {:error, :not_latest_version}

      true ->
        now = DateTime.utc_now()
        payload = Xml.encode(message, fresh_version)

        Multi.new()
        |> lock_message(message, expected_lock_version, :publish, %{
          published_version_id: fresh_version.id
        })
        |> Multi.update(:version, fn _ ->
          DraftVersion.publish_transition(fresh_version, now)
        end)
        |> Multi.insert(:audit, fn %{message: locked} ->
          audit(locked, fresh_version, :published, actor, "in_review", "published")
        end)
        |> Multi.insert(:outbox, fn %{message: locked} ->
          outbox_entry(locked, fresh_version, publish_event_type(locked), payload)
        end)
        |> supersede_predecessor(message, actor)
        |> transact()
        |> normalize_multi(:message)
        |> translate_dedupe_error()
        |> notify(:published)
    end
  end

  defp publish_event_type(%AlertMessage{msg_type: :update}), do: :corrected
  defp publish_event_type(%AlertMessage{msg_type: :cancel}), do: :cancelled
  defp publish_event_type(_), do: :published

  # Supersede the referenced predecessor when a correction/cancellation publishes.
  defp supersede_predecessor(multi, %AlertMessage{references_message_id: nil}, _actor), do: multi

  defp supersede_predecessor(multi, %AlertMessage{references_message_id: ref_id}, actor) do
    multi
    |> Multi.run(:predecessor, fn repo, _ ->
      case repo.get(AlertMessage, ref_id) do
        nil -> {:ok, nil}
        predecessor -> {:ok, predecessor}
      end
    end)
    |> Multi.merge(fn
      %{predecessor: nil} ->
        Multi.new()

      %{predecessor: %AlertMessage{workflow_state: :published} = predecessor} ->
        {:ok, :superseded} = StateMachine.transition(:published, :supersede)

        Multi.new()
        |> Multi.update(
          :supersede,
          predecessor
          |> Ecto.Changeset.change(%{workflow_state: :superseded})
          |> Ecto.Changeset.optimistic_lock(:lock_version)
        )
        |> Multi.insert(:supersede_audit, fn %{supersede: sup} ->
          audit(sup, nil, :cancellation_created, actor, "published", "superseded")
        end)

      %{predecessor: _other} ->
        Multi.new()
    end)
  end

  # --- Use cases: corrections and cancellations ------------------------------

  @doc """
  Creates a correction (`:update`) draft derived from a published message.

  The new message references the published one via a stable CAP `references`
  string and its own `references_message_id`. Content is seeded from the
  published version and can then go through the normal review/publish flow.
  """
  def create_correction(%AlertMessage{} = published, overrides, actor \\ "system") do
    derive(published, :update, :correction_created, overrides, actor)
  end

  @doc """
  Creates a cancellation (`:cancel`) draft derived from a published message.
  """
  def create_cancellation(%AlertMessage{} = published, overrides, actor \\ "system") do
    derive(published, :cancel, :cancellation_created, overrides, actor)
  end

  defp derive(%AlertMessage{} = published, msg_type, audit_action, overrides, actor) do
    with true <- StateMachine.can_derive?(published) || {:error, :not_published} do
      published = Repo.preload(published, versions: version_order())
      source = published_version(published) || List.last(published.versions)

      message_attrs = %{
        identifier: new_identifier(published.identifier, msg_type),
        sender: published.sender,
        sent_at: DateTime.utc_now(),
        status: published.status,
        msg_type: msg_type,
        scope: published.scope,
        references_text: cap_reference(published),
        references_message_id: published.id
      }

      version_attrs =
        source
        |> Map.take(~w(headline description instruction event category urgency severity
                       certainty language effective_at onset_at expires_at
                       area_description geocodes extensions)a)
        |> Map.merge(Map.new(overrides))

      Multi.new()
      |> Multi.insert(:message, AlertMessage.create_changeset(%AlertMessage{}, message_attrs))
      |> Multi.insert(:version, fn %{message: message} ->
        DraftVersion.content_changeset(%DraftVersion{}, version_attrs, %{
          version_number: 1,
          alert_message_id: message.id,
          created_by: actor
        })
      end)
      |> Multi.insert(:audit, fn %{message: message, version: version} ->
        audit(message, version, audit_action, actor, nil, "drafting")
      end)
      |> transact()
      |> normalize_multi(:message)
      |> notify(:derived)
    else
      {:error, _} = error -> error
    end
  end

  # --- Changesets exposed for forms (no state fields) ------------------------

  @doc "A changeset for editing content, for use with `to_form/2`."
  def change_version(%DraftVersion{} = version, attrs \\ %{}) do
    DraftVersion.content_changeset(version, attrs, %{
      version_number: version.version_number || 1,
      alert_message_id: version.alert_message_id,
      created_by: version.created_by || "system"
    })
  end

  @doc """
  Computes a structured, field-level diff between two versions for display.
  Returns a list of `%{field:, from:, to:, changed?:}`.
  """
  def diff_versions(%DraftVersion{} = from, %DraftVersion{} = to) do
    fields = ~w(headline description instruction event category urgency severity
                certainty language area_description geocodes)a

    Enum.map(fields, fn field ->
      from_val = Map.get(from, field)
      to_val = Map.get(to, field)
      %{field: field, from: from_val, to: to_val, changed?: from_val != to_val}
    end)
  end

  # --- Internal helpers ------------------------------------------------------

  # Applies the optimistic lock + workflow transition to the message atomically.
  defp lock_message(multi, message, expected_lock_version, event, extra_changes \\ %{}) do
    Multi.run(multi, :precheck, fn _repo, _changes ->
      case StateMachine.transition(message.workflow_state, event) do
        {:ok, next} -> {:ok, next}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> Multi.update(:message, fn %{precheck: next_state} ->
      message
      # Pin the lock version the caller loaded; a concurrent bump makes this
      # update match zero rows and raise StaleEntryError (caught below).
      |> struct(%{lock_version: expected_lock_version})
      |> Ecto.Changeset.change(extra_changes)
      # force_change guarantees an UPDATE is emitted (and the lock version is
      # therefore incremented) even when the workflow_state value is unchanged,
      # e.g. saving a new version keeps the message in :drafting.
      |> Ecto.Changeset.force_change(:workflow_state, next_state)
      |> Ecto.Changeset.optimistic_lock(:lock_version)
    end)
  end

  defp ensure_editable(message) do
    if StateMachine.can_edit?(message), do: :ok, else: {:error, :not_editable}
  end

  defp ensure_latest(message, version) do
    if is_latest?(message, version), do: :ok, else: {:error, :not_latest_version}
  end

  defp is_latest?(message, version) do
    message = Repo.preload(message, [versions: version_order()], force: true)
    latest = List.last(message.versions)
    latest && latest.id == version.id
  end

  defp next_version_number(message) do
    message = Repo.preload(message, [versions: version_order()], force: true)

    message.versions
    |> Enum.map(& &1.version_number)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  @content_keys ~w(headline description instruction event category urgency severity
                   certainty language effective_at onset_at expires_at
                   area_description geocodes extensions)a

  # Snapshot the latest version's content as a string-keyed map to serve as the
  # base for the next version.
  defp base_content(message) do
    message = Repo.preload(message, [versions: version_order()], force: true)

    case List.last(message.versions) do
      nil ->
        %{}

      latest ->
        Map.new(@content_keys, fn key -> {Atom.to_string(key), Map.get(latest, key)} end)
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp published_version(%AlertMessage{published_version_id: nil}), do: nil

  defp published_version(%AlertMessage{published_version_id: id, versions: versions})
       when is_list(versions) do
    Enum.find(versions, &(&1.id == id))
  end

  defp audit(message, version, action, actor, from_state, to_state) do
    AuditEvent.changeset(%AuditEvent{}, %{
      alert_message_id: message.id,
      draft_version_id: version && version.id,
      action: action,
      actor: actor,
      from_state: from_state,
      to_state: to_state,
      metadata: %{},
      occurred_at: DateTime.utc_now()
    })
  end

  defp outbox_entry(message, version, event_type, payload) do
    OutboxEntry.changeset(%OutboxEntry{}, %{
      alert_message_id: message.id,
      draft_version_id: version.id,
      event_type: event_type,
      status: :pending,
      dedupe_key: "publish:" <> version.id,
      payload_xml: payload
    })
  end

  # Build a stable CAP <references> value: "sender,identifier,sent".
  defp cap_reference(%AlertMessage{} = message) do
    sent = message.sent_at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    Enum.join([message.sender, message.identifier, sent], ",")
  end

  # Derive a stable identifier for a correction/cancellation from the original.
  defp new_identifier(base_identifier, msg_type) do
    suffix =
      case msg_type do
        :update -> "-UPD"
        :cancel -> "-CANCEL"
      end

    stamp = DateTime.utc_now() |> DateTime.to_unix()
    base_identifier <> suffix <> "-" <> Integer.to_string(stamp)
  end

  # A losing optimistic-lock writer surfaces as a StaleEntryError from the
  # transaction; translate to the documented `{:error, :stale}` tuple so callers
  # (and the UI) can prompt a reload instead of crashing.
  defp transact(multi) do
    Repo.transaction(multi)
  rescue
    Ecto.StaleEntryError -> {:error, :stale}
  end

  defp normalize_multi({:error, :stale}, _key), do: {:error, :stale}

  defp normalize_multi({:ok, changes}, :message) do
    # Reload with versions preloaded so callers always get consistent, fully
    # loaded aggregate state (correct lock_version + latest versions).
    {:ok, get_message!(Map.fetch!(changes, :message).id)}
  end

  defp normalize_multi({:error, _step, %Ecto.Changeset{} = changeset, _}, _key),
    do: {:error, changeset}

  defp normalize_multi({:error, _step, reason, _}, _key), do: {:error, reason}

  # Broadcasts a change event on success so concurrent viewers refresh. Passes
  # errors through untouched.
  defp notify({:ok, %AlertMessage{} = message} = result, event) do
    broadcast(message.id, event)
    result
  end

  defp notify(other, _event), do: other

  defp translate_dedupe_error({:error, %Ecto.Changeset{errors: errors}} = result) do
    if Keyword.has_key?(errors, :dedupe_key) do
      {:error, :duplicate_publish}
    else
      result
    end
  end

  defp translate_dedupe_error(other), do: other

  def default_sender, do: @default_sender

  @doc false
  def cap_enums, do: Enums
end
