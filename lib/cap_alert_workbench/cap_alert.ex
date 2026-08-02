defmodule CapAlertWorkbench.CapAlert do
  @moduledoc """
  Public use-case boundary (application/domain service) for the CAP alert
  workbench.

  LiveViews and API controllers MUST call the functions in this module; they
  never touch `workflow_state` or other status columns directly. Every state
  transition goes through `StateMachine` via pattern matching, and every
  publishing step is wrapped in a single database transaction that also writes
  the audit event and the notification outbox row.

  CAP content that varies per region lives in a list of `AlertInfo` embeds on
  each version, mirroring the CAP 1.2 multi-`<info>` structure.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias CapAlertWorkbench.Repo

  alias CapAlertWorkbench.CapAlert.{
    Alert,
    AlertInfo,
    AlertVersion,
    AuditEvent,
    NotificationOutbox,
    StateMachine,
    CapXml,
    VersionDiff,
    Enums
  }

  @pubsub CapAlertWorkbench.PubSub

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  def list_alerts do
    Alert
    |> order_by(desc: :updated_at)
    |> Repo.all()
  end

  @doc "List alerts together with their latest version for index views (no N+1)."
  def list_alerts_with_latest do
    alerts = list_alerts()
    ids = Enum.map(alerts, & &1.latest_version_id) |> Enum.reject(&is_nil/1)

    versions =
      if ids == [] do
        %{}
      else
        AlertVersion
        |> where([v], v.id in ^ids)
        |> Repo.all()
        |> Map.new(&{&1.id, &1})
      end

    Enum.map(alerts, fn alert ->
      {alert, Map.get(versions, alert.latest_version_id)}
    end)
  end

  def get_alert(identifier), do: Repo.get(Alert, identifier)
  def get_alert!(identifier), do: Repo.get!(Alert, identifier)

  @doc "Load an alert together with its latest and published versions."
  def load_alert(identifier) do
    case Repo.get(Alert, identifier) do
      nil ->
        nil

      alert ->
        %{
          alert: alert,
          latest_version: alert.latest_version_id && get_version(alert.latest_version_id),
          published_version:
            alert.published_version_id && get_version(alert.published_version_id),
          versions: list_versions(identifier),
          audit_events: list_audit_events(identifier),
          outbox: list_outbox(identifier)
        }
    end
  end

  def list_versions(alert_identifier) do
    AlertVersion
    |> where(alert_identifier: ^alert_identifier)
    |> order_by(asc: :version_number)
    |> Repo.all()
  end

  def get_version(id), do: Repo.get(AlertVersion, id)
  def get_version!(id), do: Repo.get!(AlertVersion, id)

  def get_version_for_edit!(id) do
    version = Repo.get!(AlertVersion, id)

    if StateMachine.editable?(version.workflow_state) do
      {:ok, version}
    else
      {:error, :not_editable}
    end
  end

  def list_audit_events(alert_identifier) do
    AuditEvent
    |> where(alert_identifier: ^alert_identifier)
    |> order_by(asc: :inserted_at)
    |> Repo.all()
  end

  def list_outbox(alert_identifier) do
    NotificationOutbox
    |> where(alert_identifier: ^alert_identifier)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  def latest_version(%Alert{latest_version_id: nil}), do: nil
  def latest_version(%Alert{latest_version_id: id}), do: get_version(id)

  def published_version(%Alert{published_version_id: nil}), do: nil
  def published_version(%Alert{published_version_id: id}), do: get_version(id)

  def diff_versions(%AlertVersion{} = old, %AlertVersion{} = new) do
    VersionDiff.diff(old, new)
  end

  def count_versions(alert_identifier) do
    Repo.aggregate(
      from(v in AlertVersion, where: v.alert_identifier == ^alert_identifier),
      :count
    )
  end

  # ---------------------------------------------------------------------------
  # Create
  # ---------------------------------------------------------------------------

  @type actor :: String.t()

  @spec create_alert(map(), actor(), keyword()) :: {:ok, map()} | {:error, Changeset.t()}
  def create_alert(attrs, actor \\ "system", opts \\ []) do
    attrs = normalize_keys(attrs)
    workflow_state = Keyword.get(opts, :workflow_state, :draft)

    result =
      Repo.transaction(fn ->
        with {:ok, alert} <- do_create_alert(attrs),
             {:ok, version} <- do_create_first_version(alert, attrs, workflow_state),
             {:ok, alert} <- update_alert_latest(alert, version),
             {:ok, _audit} <-
               record_audit(alert.identifier, version.id, actor, "created", %{
                 "version_number" => version.version_number,
                 "workflow_state" => Atom.to_string(workflow_state)
               }) do
          %{alert: alert, version: version}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, %{alert: alert} = data} ->
        broadcast_alert(alert.identifier, {:alert_created, alert})
        {:ok, data}

      other ->
        other
    end
  end

  defp do_create_alert(attrs) do
    %Alert{}
    |> Alert.changeset(Map.take(attrs, ["identifier", "sender", "state"]))
    |> Repo.insert()
  end

  defp do_create_first_version(alert, attrs, workflow_state) do
    number = next_version_number(alert.identifier)

    params =
      version_params(attrs)
      |> Map.merge(%{
        "alert_identifier" => alert.identifier,
        "version_number" => number,
        "workflow_state" => Atom.to_string(workflow_state),
        "status" => attrs["status"] || attrs[:status] || "draft",
        "msg_type" => attrs["msg_type"] || attrs[:msg_type] || "alert",
        "scope" => attrs["scope"] || attrs[:scope] || "public",
        "sent" => attrs["sent"] || attrs[:sent] || now(),
        "sender" => alert.sender
      })

    %AlertVersion{lock_version: 0}
    |> AlertVersion.changeset(params)
    |> Repo.insert()
  end

  defp update_alert_latest(alert, version) do
    alert
    |> Changeset.change(latest_version_id: version.id)
    |> Repo.update()
  end

  # ---------------------------------------------------------------------------
  # Edit draft (optimistic locking)
  # ---------------------------------------------------------------------------

  @spec edit_draft(AlertVersion.t(), map(), actor()) ::
          {:ok, AlertVersion.t()} | {:error, :stale | :not_editable | Changeset.t()}
  def edit_draft(%AlertVersion{} = version, attrs, actor \\ "editor") do
    result =
      Repo.transaction(fn ->
        locked = lock_version(version.id)

        if not StateMachine.editable?(locked.workflow_state) do
          Repo.rollback(:not_editable)
        end

        params =
          version_params(attrs)
          |> Map.put("workflow_state", Atom.to_string(locked.workflow_state))

        changeset = AlertVersion.changeset(locked, params)

        try do
          case Repo.update(changeset) do
            {:ok, updated} ->
              {:ok, _audit} =
                record_audit(updated.alert_identifier, updated.id, actor, "edited", %{})

              updated

            {:error, changeset} ->
              Repo.rollback(changeset)
          end
        rescue
          Ecto.StaleEntryError -> Repo.rollback(:stale)
        end
      end)

    case result do
      {:ok, updated} ->
        broadcast_version(updated.alert_identifier, {:version_updated, updated})
        {:ok, updated}

      other ->
        other
    end
  end

  # ---------------------------------------------------------------------------
  # Workflow commands
  # ---------------------------------------------------------------------------

  @spec submit_for_review(AlertVersion.t(), actor()) ::
          {:ok, AlertVersion.t()} | {:error, term()}
  def submit_for_review(%AlertVersion{} = version, actor \\ "editor") do
    result =
      transition_version(version, :submit, actor, fn locked ->
        Changeset.change(locked, workflow_state: :in_review)
      end)

    broadcast_on_ok(result, :version_updated)
  end

  @spec withdraw_from_review(AlertVersion.t(), actor()) ::
          {:ok, AlertVersion.t()} | {:error, term()}
  def withdraw_from_review(%AlertVersion{} = version, actor \\ "editor") do
    result =
      transition_version(version, :withdraw, actor, fn locked ->
        Changeset.change(locked, workflow_state: :draft)
      end)

    broadcast_on_ok(result, :version_updated)
  end

  @doc """
  Create a new draft based on a version that is currently in review, leaving
  the old version in `:in_review`. This deliberately allows the "stale review
  conclusion vs. new draft" race: a review submitted for the old version will
  be rejected because it is no longer the latest version.
  """
  @spec revise(AlertVersion.t(), actor()) :: {:ok, AlertVersion.t()} | {:error, term()}
  def revise(%AlertVersion{} = version, actor \\ "editor") do
    result =
      Repo.transaction(fn ->
        alert = lock_alert(version.alert_identifier)
        locked = lock_version(version.id)

        with :ok <- assert_state_current(version, locked),
             :ok <- assert_latest(alert, locked),
             {:ok, new_version} <- copy_as_new_draft(alert, locked, actor) do
          new_version
        else
          {:error, :not_latest} -> Repo.rollback(:not_latest_version)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    broadcast_on_ok(result, :version_created)
  end

  @spec review(AlertVersion.t(), :approve | :reject, String.t() | nil, actor()) ::
          {:ok, AlertVersion.t()} | {:error, term()}
  def review(%AlertVersion{} = version, decision, comment, actor \\ "reviewer") do
    result =
      Repo.transaction(fn ->
        alert = lock_alert(version.alert_identifier)
        locked = lock_version(version.id)

        action =
          case decision do
            :approve -> :approve
            :reject -> :reject
          end

        with :ok <- assert_state_current(version, locked),
             :ok <- assert_latest(alert, locked),
             {:ok, next_state} <- StateMachine.transition(locked.workflow_state, action),
             {:ok, next_state} <- validate_review_guard(locked, alert, next_state),
             changeset <-
               Changeset.change(locked,
                 workflow_state: next_state,
                 review_comment: comment,
                 reviewed_by: actor,
                 reviewed_at: now()
               ),
             {:ok, updated} <- Repo.update(changeset),
             {:ok, _audit} <-
               record_audit(alert.identifier, updated.id, actor, Atom.to_string(action), %{
                 "comment" => comment
               }) do
          updated
        else
          {:error, :not_latest} -> Repo.rollback(:stale_review)
          {:error, :not_latest_version} -> Repo.rollback(:stale_review)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    broadcast_on_ok(result, :version_updated)
  end

  defp validate_review_guard(locked, alert, next_state) do
    if StateMachine.reviewable?(locked.workflow_state, locked.id == alert.latest_version_id) do
      {:ok, next_state}
    else
      {:error, :stale_review}
    end
  end

  # ---------------------------------------------------------------------------
  # Publish
  # ---------------------------------------------------------------------------

  @spec publish(AlertVersion.t(), actor()) :: {:ok, AlertVersion.t()} | {:error, term()}
  def publish(%AlertVersion{} = version, actor \\ "publisher") do
    result =
      Repo.transaction(fn ->
        alert = lock_alert(version.alert_identifier)
        locked = lock_version(version.id)

        with :ok <- assert_state_current(version, locked),
             :ok <- assert_latest(alert, locked),
             :ok <- assert_publishable(locked, alert),
             {:ok, next_state} <- StateMachine.transition(locked.workflow_state, :publish),
             xml_payload <- CapXml.encode(version_to_cap_fields(locked)),
             changeset <-
               Changeset.change(locked,
                 workflow_state: next_state,
                 published_at: now(),
                 xml_payload: xml_payload,
                 status: :actual
               ),
             {:ok, updated} <- Repo.update(changeset),
             {:ok, _prev} <- supersede_previous(alert, updated),
             {:ok, updated_alert} <-
               Alert.changeset(alert, %{
                 published_version_id: updated.id,
                 state: alert_state_for(updated)
               })
               |> Repo.update(),
             maybe_simulate_failure!(),
             {:ok, _audit} <-
               record_audit(alert.identifier, updated.id, actor, "published", %{
                 "msg_type" => Atom.to_string(updated.msg_type),
                 "version_number" => updated.version_number
               }),
             {:ok, _outbox} <- create_outbox(updated_alert, updated) do
          updated
        else
          {:error, :not_latest} -> Repo.rollback(:not_latest_version)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    broadcast_on_ok(result, :version_published)
  end

  defp assert_publishable(locked, alert) do
    if StateMachine.publishable?(locked.workflow_state, locked.id == alert.latest_version_id) do
      :ok
    else
      {:error, :not_publishable}
    end
  end

  defp supersede_previous(alert, %AlertVersion{msg_type: :alert}), do: {:ok, alert}

  defp supersede_previous(alert, %AlertVersion{msg_type: msg_type} = current)
       when msg_type in [:update, :cancel] do
    if alert.published_version_id && alert.published_version_id != current.id do
      prev = lock_version(alert.published_version_id)
      action = if msg_type == :cancel, do: :cancel, else: :supersede

      case StateMachine.transition(prev.workflow_state, action) do
        {:ok, next_state} ->
          prev
          |> Changeset.change(workflow_state: next_state)
          |> Repo.update()

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, alert}
    end
  end

  defp alert_state_for(%AlertVersion{msg_type: :cancel}), do: :cancelled
  defp alert_state_for(_), do: :active

  defp maybe_simulate_failure! do
    if Application.get_env(:cap_alert_workbench, :simulate_publish_failure, false) do
      Repo.rollback(:simulated_failure)
    end
  end

  # ---------------------------------------------------------------------------
  # Same-alert correction / cancellation (new version within the same alert)
  # ---------------------------------------------------------------------------

  @spec create_correction(map(), actor()) :: {:ok, AlertVersion.t()} | {:error, term()}
  def create_correction(attrs, actor \\ "editor") do
    create_followup(:update, attrs, actor)
  end

  @spec create_cancellation(map(), actor()) :: {:ok, AlertVersion.t()} | {:error, term()}
  def create_cancellation(attrs, actor \\ "editor") do
    create_followup(:cancel, attrs, actor)
  end

  defp create_followup(msg_type, attrs, actor) do
    result =
      Repo.transaction(fn ->
        identifier = attrs["alert_identifier"] || attrs[:alert_identifier]
        alert = lock_alert(identifier)

        published =
          if alert.published_version_id do
            lock_version(alert.published_version_id)
          end

        if is_nil(published) do
          Repo.rollback(:no_published_version)
        else
          number = next_version_number(alert.identifier)
          references = build_references(published)

          params =
            version_params(attrs)
            |> Map.merge(%{
              "alert_identifier" => alert.identifier,
              "version_number" => number,
              "workflow_state" => "draft",
              "msg_type" => Atom.to_string(msg_type),
              "status" => "actual",
              "sender" => published.sender,
              "scope" => Atom.to_string(published.scope),
              "references" => references,
              "based_on_version_id" => published.id,
              "sent" => now(),
              "infos" => infos_to_params(published.infos)
            })

          changeset =
            %AlertVersion{lock_version: 0}
            |> AlertVersion.changeset(params)

          with {:ok, new_version} <- Repo.insert(changeset),
               {:ok, _alert} <-
                 Alert.changeset(alert, %{latest_version_id: new_version.id}) |> Repo.update(),
               {:ok, _audit} <-
                 record_audit(alert.identifier, new_version.id, actor, "#{msg_type}_created", %{
                   "based_on_version_id" => published.id,
                   "references" => references
                 }) do
            new_version
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end
      end)

    broadcast_on_ok(result, :version_created)
  end

  # ---------------------------------------------------------------------------
  # C1 correction as a NEW alert aggregate
  # ---------------------------------------------------------------------------

  @doc """
  Create a C1 correction alert derived from the latest published version of
  `source_identifier`.

  The new alert gets the identifier `"<source>-C1"` (or a custom one), its
  first version has `msgType=Update` and `references` pointing precisely at the
  *first-round* published document of the source. Info segments are split by
  region and the 440900 region is raised to `Extreme`.

  Concurrency: the source alert row is locked `FOR UPDATE`, serializing C1
  creation; the primary-key unique constraint on the new identifier turns a
  duplicate attempt into a changeset error rather than a second C1/outbox.
  """
  @spec create_correction_alert(map(), actor()) ::
          {:ok, map()} | {:error, term()}
  def create_correction_alert(attrs, actor \\ "editor") do
    attrs = normalize_keys(attrs)

    source_id = attrs["source_identifier"] || attrs[:source_identifier]

    result =
      Repo.transaction(fn ->
        source_alert = lock_alert(source_id)

        source_version =
          if source_alert.published_version_id do
            lock_version(source_alert.published_version_id)
          end

        if is_nil(source_version) do
          Repo.rollback(:no_published_version)
        else
          new_identifier =
            case attrs["identifier"] do
              id when is_binary(id) and id != "" -> id
              _ -> "#{source_id}-C1"
            end

          first_round = first_published_version(source_id) || source_version
          references = build_references(first_round)

          infos = c1_infos(source_version)

          new_alert_attrs = %{
            "identifier" => new_identifier,
            "sender" => source_version.sender,
            "state" => "active"
          }

          with {:ok, new_alert} <-
                 %Alert{} |> Alert.changeset(new_alert_attrs) |> Repo.insert(),
               number = next_version_number(new_identifier),
               params = %{
                 "alert_identifier" => new_identifier,
                 "version_number" => number,
                 "workflow_state" => "draft",
                 "status" => "actual",
                 "msg_type" => "update",
                 "scope" => Atom.to_string(source_version.scope),
                 "sender" => source_version.sender,
                 "sent" => now(),
                 "references" => references,
                 "based_on_version_id" => source_version.id,
                 "infos" => infos_to_params(infos),
                 "extensions" => encode_elements(source_version.extensions)
               },
               changeset = %AlertVersion{lock_version: 0} |> AlertVersion.changeset(params),
               {:ok, new_version} <- Repo.insert(changeset),
               {:ok, _} <-
                 Alert.changeset(new_alert, %{latest_version_id: new_version.id})
                 |> Repo.update(),
               {:ok, _audit} <-
                 record_audit(new_identifier, new_version.id, actor, "c1_created", %{
                   "source_identifier" => source_id,
                   "based_on_version_id" => source_version.id,
                   "references" => references
                 }) do
            %{alert: new_alert, version: new_version}
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end
      end)

    case result do
      {:ok, %{alert: alert} = data} ->
        broadcast_alert(alert.identifier, {:alert_created, alert})
        {:ok, data}

      other ->
        other
    end
  end

  @doc """
  Build the C1 info list from a published version. Info segments that cover
  multiple geocodes are split into one info per geocode; the segment covering
  440900 has its severity raised to `:extreme`, while 440800 keeps `:severe`.
  """
  @spec c1_infos(AlertVersion.t()) :: [AlertInfo.t()]
  def c1_infos(%AlertVersion{infos: infos}) do
    Enum.flat_map(infos, fn info ->
      case info.geocodes do
        [_single] ->
          [maybe_raise_440900(info)]

        gcs when is_list(gcs) and length(gcs) > 1 ->
          Enum.map(gcs, fn gc ->
            %{info | geocodes: [gc], area_desc: gc.value}
            |> maybe_raise_440900()
          end)

        _ ->
          [info]
      end
    end)
  end

  defp maybe_raise_440900(%AlertInfo{} = info) do
    values = Enum.map(info.geocodes, & &1.value)

    if "440900" in values do
      %{info | severity: :extreme}
    else
      info
    end
  end

  @doc "Return the earliest ever-published version of an alert (the first-round document)."
  def first_published_version(alert_identifier) do
    AlertVersion
    |> where(alert_identifier: ^alert_identifier)
    |> where([v], v.workflow_state in [:published, :superseded, :cancelled])
    |> order_by(asc: :version_number)
    |> limit(1)
    |> Repo.one()
  end

  defp build_references(%AlertVersion{} = published) do
    sent =
      case published.sent do
        %DateTime{} = dt -> DateTime.to_iso8601(dt)
        other -> to_string(other)
      end

    "#{published.sender},#{published.alert_identifier},#{sent}"
  end

  # ---------------------------------------------------------------------------
  # CAP XML import / export
  # ---------------------------------------------------------------------------

  @spec export_cap(AlertVersion.t()) :: String.t()
  def export_cap(%AlertVersion{} = version), do: CapXml.encode(version_to_cap_fields(version))

  @spec import_cap(String.t(), actor()) :: {:ok, map()} | {:error, term()}
  def import_cap(xml, actor \\ "importer") when is_binary(xml) do
    with {:ok, fields, _element} <- CapXml.decode(xml),
         {:ok, identifier} <- fetch_identifier(fields),
         attrs <- cap_fields_to_attrs(fields),
         {:ok, result} <- upsert_from_import(identifier, attrs, actor) do
      {:ok, result}
    end
  end

  defp fetch_identifier(%{identifier: id}) when is_binary(id) and id != "", do: {:ok, id}
  defp fetch_identifier(_), do: {:error, :missing_identifier}

  defp upsert_from_import(identifier, attrs, actor) do
    case get_alert(identifier) do
      nil ->
        # External messages always enter the review queue, never as editable
        # drafts, so an imported update cannot silently overwrite published
        # region-level severity.
        create_alert(Map.put(attrs, "identifier", identifier), actor, workflow_state: :in_review)

      %Alert{} = alert ->
        base = latest_version(alert) || published_version(alert)
        number = next_version_number(identifier)

        params =
          version_params(attrs)
          |> Map.merge(%{
            "alert_identifier" => identifier,
            "version_number" => number,
            "workflow_state" => "in_review",
            "based_on_version_id" => base && base.id
          })

        result =
          Repo.transaction(fn ->
            with {:ok, new_version} <-
                   %AlertVersion{lock_version: 0}
                   |> AlertVersion.changeset(params)
                   |> Repo.insert(),
                 {:ok, _alert} <-
                   Alert.changeset(alert, %{latest_version_id: new_version.id}) |> Repo.update(),
                 {:ok, _audit} <-
                   record_audit(identifier, new_version.id, actor, "imported", %{
                     "workflow_state" => "in_review"
                   }) do
              %{alert: alert, version: new_version}
            else
              {:error, reason} -> Repo.rollback(reason)
            end
          end)

        case result do
          {:ok, %{version: new_version} = data} ->
            broadcast_version(identifier, {:version_created, new_version})
            {:ok, data}

          other ->
            other
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Outbox draining (called by the publisher worker)
  # ---------------------------------------------------------------------------

  @doc "Claim up to `limit` pending outbox rows using SELECT ... FOR UPDATE SKIP LOCKED."
  def claim_pending_outbox(limit \\ 20) do
    Repo.all(
      from o in NotificationOutbox,
        where: o.status == :pending,
        order_by: [asc: :inserted_at],
        limit: ^limit,
        lock: "FOR UPDATE SKIP LOCKED"
    )
  end

  def mark_outbox_published(%NotificationOutbox{} = outbox) do
    outbox
    |> Changeset.change(status: :published, published_at: now())
    |> Repo.update()
  end

  def mark_outbox_failed(%NotificationOutbox{} = outbox, error) do
    outbox
    |> Changeset.change(
      status: :failed,
      attempts: outbox.attempts + 1,
      last_error: to_string(error)
    )
    |> Repo.update()
  end

  def broadcast_outbox(%NotificationOutbox{} = outbox) do
    payload = outbox.payload || %{}

    Phoenix.PubSub.broadcast(
      @pubsub,
      "outbox:#{outbox.alert_identifier}",
      {:outbox_event, outbox.event_type, payload}
    )

    Phoenix.PubSub.broadcast(
      @pubsub,
      "alert:#{outbox.alert_identifier}",
      {:outbox_event, outbox.event_type, payload}
    )

    :ok
  end

  # ---------------------------------------------------------------------------
  # PubSub subscriptions
  # ---------------------------------------------------------------------------

  def subscribe_alert(identifier) do
    Phoenix.PubSub.subscribe(@pubsub, "alert:#{identifier}")
    Phoenix.PubSub.subscribe(@pubsub, "outbox:#{identifier}")
  end

  def subscribe_alerts do
    Phoenix.PubSub.subscribe(@pubsub, "alerts")
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  defp transition_version(version, action, actor, change_fun) do
    Repo.transaction(fn ->
      alert = lock_alert(version.alert_identifier)
      locked = lock_version(version.id)

      with :ok <- assert_state_current(version, locked),
           :ok <- assert_latest(alert, locked),
           {:ok, next_state} <- StateMachine.transition(locked.workflow_state, action),
           changeset <-
             change_fun.(locked)
             |> Changeset.put_change(:workflow_state, next_state),
           {:ok, updated} <- Repo.update(changeset),
           {:ok, _audit} <-
             record_audit(alert.identifier, updated.id, actor, Atom.to_string(action), %{}) do
        updated
      else
        {:error, :not_latest} -> Repo.rollback(:not_latest_version)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # Guard that detects a stale client view: the caller passed a `version` struct
  # whose `workflow_state` no longer matches the freshly-locked row. This rejects
  # an old draft (e.g. a C1 draft held by another browser before it was
  # published) being acted on after the live version has already moved on,
  # returning `:not_latest_version` without mutating any region-level severity.
  defp assert_state_current(client_version, locked) do
    if client_version.workflow_state == locked.workflow_state do
      :ok
    else
      {:error, :not_latest_version}
    end
  end

  defp broadcast_on_ok({:ok, %AlertVersion{} = version} = result, message) do
    broadcast_version(version.alert_identifier, {message, version})
    result
  end

  defp broadcast_on_ok(other, _message), do: other

  defp copy_as_new_draft(alert, version, actor) do
    number = next_version_number(alert.identifier)

    params =
      version_to_attrs(version)
      |> Map.drop(["id", "inserted_at", "updated_at", "published_at", "reviewed_at"])
      |> Map.merge(%{
        "alert_identifier" => alert.identifier,
        "version_number" => number,
        "workflow_state" => "draft",
        "based_on_version_id" => version.id,
        "lock_version" => 1,
        "review_comment" => nil,
        "reviewed_by" => nil
      })

    %AlertVersion{lock_version: 0}
    |> AlertVersion.changeset(params)
    |> Repo.insert()
    |> case do
      {:ok, new_version} ->
        {:ok, _alert} =
          Alert.changeset(alert, %{latest_version_id: new_version.id}) |> Repo.update()

        {:ok, _audit} =
          record_audit(alert.identifier, new_version.id, actor, "revised", %{
            "based_on_version_id" => version.id
          })

        {:ok, new_version}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp assert_latest(alert, version) do
    if alert.latest_version_id == version.id do
      :ok
    else
      {:error, :not_latest}
    end
  end

  defp lock_alert(identifier) do
    Alert
    |> where(identifier: ^identifier)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp lock_version(id) do
    AlertVersion
    |> where(id: ^id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp next_version_number(identifier) do
    count =
      Repo.aggregate(from(v in AlertVersion, where: v.alert_identifier == ^identifier), :count)

    count + 1
  end

  defp record_audit(identifier, version_id, actor, action, details) do
    %AuditEvent{}
    |> AuditEvent.changeset(%{
      alert_identifier: identifier,
      version_id: version_id,
      actor: actor,
      action: action,
      details: details,
      inserted_at: now()
    })
    |> Repo.insert()
  end

  defp create_outbox(alert, version) do
    %NotificationOutbox{}
    |> NotificationOutbox.changeset(%{
      alert_identifier: alert.identifier,
      version_id: version.id,
      event_type: "alert.#{version.msg_type}",
      payload: %{
        "identifier" => alert.identifier,
        "version_id" => version.id,
        "version_number" => version.version_number,
        "msg_type" => Atom.to_string(version.msg_type),
        "infos" =>
          Enum.map(version.infos, fn info ->
            %{
              "event" => info.event,
              "headline" => info.headline,
              "severity" => info.severity && Atom.to_string(info.severity),
              "urgency" => info.urgency && Atom.to_string(info.urgency),
              "areas" => Enum.map(info.geocodes, & &1.value)
            }
          end),
        "published_at" => DateTime.to_iso8601(version.published_at)
      },
      status: :pending
    })
    |> Repo.insert()
  end

  defp broadcast_version(identifier, message) do
    Phoenix.PubSub.broadcast(@pubsub, "alert:#{identifier}", message)
    Phoenix.PubSub.broadcast(@pubsub, "alerts", {:alert_changed, identifier})
  end

  defp broadcast_alert(identifier, message) do
    Phoenix.PubSub.broadcast(@pubsub, "alert:#{identifier}", message)
    Phoenix.PubSub.broadcast(@pubsub, "alerts", message)
  end

  # ---------------------------------------------------------------------------
  # Parameter / field conversion
  # ---------------------------------------------------------------------------

  defp version_params(%{} = attrs) do
    attrs
    |> normalize_keys()
    |> normalize_infos()
    |> normalize_extensions()
  end

  defp normalize_keys(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)

  defp normalize_infos(%{"infos" => infos} = params) when is_map(infos) do
    Map.put(params, "infos", infos)
  end

  defp normalize_infos(%{"infos" => infos} = params) when is_list(infos) do
    Map.put(params, "infos", infos)
  end

  defp normalize_infos(params), do: params

  defp normalize_extensions(%{"extensions" => list} = params) when is_list(list) do
    Map.put(
      params,
      "extensions",
      Enum.map(list, fn
        %{"name" => _} = map -> map
        {_name, _attrs, _children} = el -> CapXml.element_to_map(el)
      end)
    )
  end

  defp normalize_extensions(params), do: params

  defp encode_elements(nil), do: []
  defp encode_elements(list) when is_list(list), do: list

  defp infos_to_params(infos) when is_list(infos) do
    Enum.map(infos, fn info ->
      info
      |> Map.from_struct()
      |> Map.drop([:__meta__])
      |> Map.new(fn
        {k, %DateTime{} = dt} -> {Atom.to_string(k), dt}
        {k, v} when is_atom(v) and not is_nil(v) -> {Atom.to_string(k), Atom.to_string(v)}
        {k, v} -> {Atom.to_string(k), v}
      end)
      |> Map.put("geocodes", geocodes_to_params(info.geocodes))
      |> Map.put("extensions", info.extensions || [])
    end)
  end

  defp geocodes_to_params(geocodes) when is_list(geocodes) do
    Enum.map(geocodes, fn gc ->
      %{"value_name" => gc.value_name, "value" => gc.value}
    end)
  end

  defp version_to_cap_fields(%AlertVersion{} = v) do
    %{
      identifier: v.alert_identifier,
      sender: v.sender,
      sent: v.sent,
      status: v.status,
      msg_type: v.msg_type,
      scope: v.scope,
      references: v.references,
      infos: Enum.map(v.infos, &info_to_cap_fields/1),
      alert_extensions: elements_from_json(v.extensions)
    }
  end

  defp info_to_cap_fields(%AlertInfo{} = info) do
    %{
      language: info.language,
      event: info.event,
      urgency: info.urgency,
      severity: info.severity,
      certainty: info.certainty,
      headline: info.headline,
      description: info.description,
      instruction: info.instruction,
      area_desc: info.area_desc,
      geocodes:
        Enum.map(info.geocodes, fn gc -> %{value_name: gc.value_name, value: gc.value} end),
      info_extensions: elements_from_json(info.extensions)
    }
  end

  defp elements_from_json(nil), do: []

  defp elements_from_json(list) when is_list(list) do
    Enum.map(list, &CapXml.element_from_map/1)
  end

  defp version_to_attrs(%AlertVersion{} = v) do
    v
    |> Map.from_struct()
    |> Map.drop([:__meta__, :alert, :based_on])
    |> Map.new(fn
      {k, %DateTime{} = dt} -> {Atom.to_string(k), dt}
      {k, v} when is_atom(v) and not is_nil(v) -> {Atom.to_string(k), Atom.to_string(v)}
      {k, v} -> {Atom.to_string(k), v}
    end)
    |> Map.put("infos", infos_to_params(v.infos))
  end

  defp cap_fields_to_attrs(fields) do
    %{
      "sender" => fields[:sender],
      "sent" => fields[:sent] && parse_sent(fields[:sent]),
      "status" => fields[:status] && Atom.to_string(fields[:status]),
      "msg_type" => fields[:msg_type] && Atom.to_string(fields[:msg_type]),
      "scope" => fields[:scope] && Atom.to_string(fields[:scope]),
      "infos" => Enum.map(fields[:infos] || [], &info_fields_to_attrs/1),
      "extensions" => Enum.map(fields[:alert_extensions] || [], &CapXml.element_to_map/1)
    }
  end

  defp info_fields_to_attrs(info) do
    %{
      "language" => info[:language],
      "event" => info[:event],
      "urgency" => info[:urgency] && Atom.to_string(info[:urgency]),
      "severity" => info[:severity] && Atom.to_string(info[:severity]),
      "certainty" => info[:certainty] && Atom.to_string(info[:certainty]),
      "headline" => info[:headline],
      "description" => info[:description],
      "instruction" => info[:instruction],
      "area_desc" => info[:area_desc],
      "geocodes" =>
        Enum.map(info[:geocodes] || [], fn gc ->
          %{"value_name" => gc[:value_name], "value" => gc[:value]}
        end),
      "extensions" => Enum.map(info[:info_extensions] || [], &CapXml.element_to_map/1)
    }
  end

  defp parse_sent(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> s
    end
  end

  defp parse_sent(other), do: other

  @doc "Expose the enums module for the web layer."
  def enums, do: Enums
end
