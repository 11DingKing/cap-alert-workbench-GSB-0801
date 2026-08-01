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
    InfoBlock,
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

  @doc """
  Returns the full derivation chain any given message belongs to, oldest first.

  The chain is rooted at the original alert (whose identifier has no `-C<n>`
  suffix) and includes every correction/cancellation derived from it, in
  ascending chain-sequence order. This lets the UI display the complete lineage
  even after a message has been superseded. Versions are preloaded on each link.
  """
  def message_chain(%AlertMessage{identifier: identifier}) do
    root = chain_root(identifier)
    like = root <> "-C%"

    from(m in AlertMessage,
      where: m.identifier == ^root or like(m.identifier, ^like)
    )
    |> Repo.all()
    |> Repo.preload(versions: version_order())
    |> Enum.sort_by(&chain_seq(&1.identifier))
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
          audit(sup, nil, :superseded, actor, "published", "superseded")
        end)

      %{predecessor: _other} ->
        Multi.new()
    end)
  end

  # --- Use cases: corrections and cancellations ------------------------------

  @doc """
  Creates a correction (`:update`) draft derived from the latest published
  message.

  `overrides` may contain:

    * `:infos` — an explicit list of info-block maps to use verbatim, or
    * `:region_severities` — a map of `geocode => severity` used to split the
      source area into per-region info blocks (a region whose severity differs
      from its neighbours becomes its own `<info>`), plus optional
      `:region_headlines` / `:region_descriptions` overrides keyed by geocode.

  The correction references the source message exactly (stable
  `references_message_id` + CAP `references` text) and is assigned a
  deterministic identifier (`<base>-C<n>`). Because that identifier is unique,
  creation is idempotent: concurrent attempts, stale locks, or repeated clicks
  can never produce a second `-C1`.
  """
  def create_correction(%AlertMessage{} = source, overrides \\ %{}, actor \\ "system") do
    derive(source, :update, :correction_created, overrides, actor)
  end

  @doc """
  Creates a cancellation (`:cancel`) draft derived from the latest published
  message. Idempotent on its deterministic identifier, like corrections.
  """
  def create_cancellation(%AlertMessage{} = source, overrides \\ %{}, actor \\ "system") do
    derive(source, :cancel, :cancellation_created, overrides, actor)
  end

  defp derive(%AlertMessage{} = source, msg_type, audit_action, overrides, actor) do
    with true <- StateMachine.can_derive?(source) || {:error, :not_published} do
      source = Repo.preload(source, versions: version_order())
      source_version = published_version(source) || List.last(source.versions)

      overrides = Map.new(overrides)
      infos = build_correction_infos(source_version, overrides)

      version_attrs = %{"infos" => infos, "extensions" => source_version.extensions}

      # Idempotency guard: a given derivation type (:update / :cancel) off a given
      # source is created at most once. Repeated or concurrent requests return
      # the existing derived message instead of a second one.
      case Repo.get_by(AlertMessage, references_message_id: source.id, msg_type: msg_type) do
        %AlertMessage{} = existing ->
          {:ok, get_message!(existing.id)}

        nil ->
          identifier = next_chain_identifier(source.identifier, msg_type)

          message_attrs = %{
            identifier: identifier,
            sender: source.sender,
            sent_at: DateTime.utc_now(),
            status: source.status,
            msg_type: msg_type,
            scope: source.scope,
            references_text: cap_reference(source),
            references_message_id: source.id
          }

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
          |> translate_derive_clash(source.id, msg_type)
          |> notify(:derived)
      end
    else
      {:error, _} = error -> error
    end
  end

  # Builds the info blocks for a correction. If the caller supplies explicit
  # `:infos`, use them. Otherwise, if `:region_severities` is given, split the
  # source's info blocks so each region carries its own severity (and optional
  # headline/description), preserving regions not mentioned.
  defp build_correction_infos(_source_version, %{infos: infos}) when is_list(infos), do: infos
  defp build_correction_infos(_source_version, %{"infos" => infos}) when is_list(infos), do: infos

  defp build_correction_infos(source_version, overrides) do
    region_severities = normalize_region_map(Map.get(overrides, :region_severities, %{}))
    region_headlines = normalize_region_map(Map.get(overrides, :region_headlines, %{}))
    region_descriptions = normalize_region_map(Map.get(overrides, :region_descriptions, %{}))

    source_version.infos
    |> Enum.flat_map(fn info ->
      split_info_by_region(info, region_severities, region_headlines, region_descriptions)
    end)
  end

  # Splits a single info block into one block per geocode when any of that
  # block's regions has an override; regions sharing the same (possibly
  # overridden) values are regrouped so unchanged regions stay together.
  defp split_info_by_region(info, sev, head, desc) do
    touched? = Enum.any?(info.geocodes, &Map.has_key?(sev, &1))

    if touched? do
      info.geocodes
      |> Enum.group_by(fn geo ->
        {Map.get(sev, geo, info.severity), Map.get(head, geo), Map.get(desc, geo)}
      end)
      |> Enum.map(fn {{severity, headline, description}, geocodes} ->
        base = info_to_map(info)

        base
        |> Map.put("severity", severity)
        |> Map.put("geocodes", geocodes)
        |> maybe_put("headline", headline)
        |> maybe_put("description", description)
        |> maybe_put("area_description", region_area_desc(headline, geocodes, info))
        |> Map.delete("id")
      end)
      # Keep a stable order: highest severity first, then original geocode order.
      |> Enum.sort_by(fn m -> severity_rank(m["severity"]) end)
    else
      [info_to_map(info) |> Map.delete("id")]
    end
  end

  defp region_area_desc(nil, geocodes, info) do
    # When no explicit headline/area override, describe by the geocodes carved out.
    if geocodes == info.geocodes, do: info.area_description, else: Enum.join(geocodes, "、")
  end

  defp region_area_desc(_headline, _geocodes, info), do: info.area_description

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Normalizes a region-keyed override map: keys to strings, severity values to
  # known atoms (never String.to_atom on user input).
  defp normalize_region_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), normalize_region_value(v)} end)
  end

  defp normalize_region_value(v) when is_atom(v), do: v

  defp normalize_region_value(v) when is_binary(v) do
    Enum.find(Enums.severities(), fn atom -> Atom.to_string(atom) == v end) || v
  end

  defp severity_rank(severity) do
    case Enum.find_index(Enums.severities(), &(&1 == severity)) do
      nil -> 99
      idx -> idx
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
  Computes a per-region diff between two versions.

  Each version's info blocks are flattened to a `geocode => attrs` map, then
  compared region by region. Returns a list of
  `%{geocode:, from:, to:, changes: [%{field:, from:, to:}], status:}` where
  `status` is `:added`, `:removed`, `:changed`, or `:unchanged`.
  """
  def diff_versions(%DraftVersion{} = from, %DraftVersion{} = to) do
    from_regions = regions_by_geocode(from)
    to_regions = regions_by_geocode(to)

    geocodes =
      (Map.keys(from_regions) ++ Map.keys(to_regions))
      |> Enum.uniq()
      |> Enum.sort()

    Enum.map(geocodes, fn geocode ->
      from_attrs = Map.get(from_regions, geocode)
      to_attrs = Map.get(to_regions, geocode)

      {status, changes} = region_delta(from_attrs, to_attrs)

      %{geocode: geocode, from: from_attrs, to: to_attrs, changes: changes, status: status}
    end)
  end

  @region_fields ~w(severity headline description event category urgency certainty
                    language area_description instruction)a

  # Flattens a version's info blocks into a map of geocode => comparable attrs.
  defp regions_by_geocode(%DraftVersion{infos: infos}) do
    Enum.reduce(infos, %{}, fn info, acc ->
      attrs = Map.take(info, @region_fields)

      Enum.reduce(info.geocodes, acc, fn geocode, inner ->
        Map.put(inner, geocode, attrs)
      end)
    end)
  end

  defp region_delta(nil, _to), do: {:added, []}
  defp region_delta(_from, nil), do: {:removed, []}

  defp region_delta(from_attrs, to_attrs) do
    changes =
      @region_fields
      |> Enum.map(fn field ->
        {field, Map.get(from_attrs, field), Map.get(to_attrs, field)}
      end)
      |> Enum.filter(fn {_f, a, b} -> a != b end)
      |> Enum.map(fn {field, a, b} -> %{field: field, from: a, to: b} end)

    if changes == [], do: {:unchanged, []}, else: {:changed, changes}
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

  # Snapshot the latest version's content as a string-keyed map to serve as the
  # base for the next version. Info blocks are converted to plain maps so they
  # can be re-cast through the embedded changeset.
  defp base_content(message) do
    message = Repo.preload(message, [versions: version_order()], force: true)

    case List.last(message.versions) do
      nil ->
        %{}

      latest ->
        %{
          "infos" => Enum.map(latest.infos, &info_to_map/1),
          "extensions" => latest.extensions
        }
    end
  end

  @doc """
  Converts an `InfoBlock` struct to a plain string-keyed map (used both to seed
  new versions and to build per-region views).
  """
  def info_to_map(%InfoBlock{} = info) do
    %{
      "id" => info.id,
      "language" => info.language,
      "category" => info.category,
      "event" => info.event,
      "urgency" => info.urgency,
      "severity" => info.severity,
      "certainty" => info.certainty,
      "headline" => info.headline,
      "description" => info.description,
      "instruction" => info.instruction,
      "effective_at" => info.effective_at,
      "onset_at" => info.onset_at,
      "expires_at" => info.expires_at,
      "area_description" => info.area_description,
      "geocodes" => info.geocodes,
      "extensions" => info.extensions
    }
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

  # Derived messages form a chain rooted at the original identifier. Each
  # derivation (correction or cancellation) gets the next sequence number across
  # the whole chain, so a correction off the original is `-C1` and a subsequent
  # cancellation referencing that correction is `-C2`. This keeps a single,
  # monotonically increasing lineage regardless of derivation type.
  defp next_chain_identifier(source_identifier, _msg_type) do
    root = chain_root(source_identifier)
    next_seq = chain_max_seq(root) + 1
    root <> "-C" <> Integer.to_string(next_seq)
  end

  # The root identifier is the original with any trailing `-C<n>` chain suffix
  # removed.
  defp chain_root(identifier) do
    Regex.replace(~r/-C\d+$/, identifier, "")
  end

  # Highest existing chain sequence for a given root (0 if none yet).
  defp chain_max_seq(root) do
    like = root <> "-C%"

    from(m in AlertMessage,
      where: m.identifier == ^root or like(m.identifier, ^like),
      select: m.identifier
    )
    |> Repo.all()
    |> Enum.map(&chain_seq/1)
    |> Enum.max(fn -> 0 end)
  end

  defp chain_seq(identifier) do
    case Regex.run(~r/-C(\d+)$/, identifier) do
      [_, seq] -> String.to_integer(seq)
      nil -> 0
    end
  end

  # If two concurrent derivations of the same (source, msg_type) race past the
  # existence check, one insert loses the unique-index battle; return the row
  # that actually persisted so the caller still sees a single derived message.
  defp translate_derive_clash(
         {:error, %Ecto.Changeset{errors: errors}} = result,
         source_id,
         msg_type
       ) do
    if Keyword.has_key?(errors, :identifier) do
      case Repo.get_by(AlertMessage, references_message_id: source_id, msg_type: msg_type) do
        %AlertMessage{} = existing -> {:ok, get_message!(existing.id)}
        nil -> result
      end
    else
      result
    end
  end

  defp translate_derive_clash(other, _source_id, _msg_type), do: other

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
