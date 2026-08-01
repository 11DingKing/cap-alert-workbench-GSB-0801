defmodule CapAlertWorkbench.CapAlert do
  @moduledoc """
  Public use-case boundary (application/domain service) for the CAP alert
  workbench.

  LiveViews and API controllers MUST call the functions in this module; they
  never touch `workflow_state` or other status columns directly. Every state
  transition goes through `StateMachine` via pattern matching, and every
  publishing step is wrapped in a single database transaction that also writes
  the audit event and the notification outbox row.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias CapAlertWorkbench.Repo

  alias CapAlertWorkbench.CapAlert.{
    Alert,
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

  @spec create_alert(map(), actor()) :: {:ok, map()} | {:error, Changeset.t()}
  def create_alert(attrs, actor \\ "system") do
    attrs = normalize_keys(attrs)

    result =
      Repo.transaction(fn ->
        with {:ok, alert} <- do_create_alert(attrs),
             {:ok, version} <- do_create_first_version(alert, attrs),
             {:ok, alert} <- update_alert_latest(alert, version),
             {:ok, _audit} <-
               record_audit(alert.identifier, version.id, actor, "created", %{
                 "version_number" => version.version_number
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

  defp do_create_first_version(alert, attrs) do
    number = next_version_number(alert.identifier)

    params =
      version_params(attrs)
      |> Map.merge(%{
        "alert_identifier" => alert.identifier,
        "version_number" => number,
        "workflow_state" => "draft",
        "status" => attrs["status"] || attrs[:status] || "draft",
        "msg_type" => attrs["msg_type"] || attrs[:msg_type] || "alert",
        "scope" => attrs["scope"] || attrs[:scope] || "public",
        "sent" => attrs["sent"] || attrs[:sent] || now()
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
        alert = Repo.get!(Alert, version.alert_identifier)

        with :ok <- assert_latest(alert, version),
             {:ok, new_version} <- copy_as_new_draft(alert, version, actor) do
          new_version
        else
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

        with :ok <- assert_latest(alert, locked),
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

        with :ok <- assert_latest(alert, locked),
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
  # Create correction / cancellation from a published version
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
              "event" => attrs["event"] || attrs[:event] || published.event,
              "headline" => attrs["headline"] || attrs[:headline] || published.headline,
              "description" =>
                attrs["description"] || attrs[:description] || published.description,
              "instruction" =>
                attrs["instruction"] || attrs[:instruction] || published.instruction,
              "language" => attrs["language"] || attrs[:language] || published.language,
              "urgency" => to_string(attrs["urgency"] || attrs[:urgency] || published.urgency),
              "severity" =>
                to_string(attrs["severity"] || attrs[:severity] || published.severity),
              "certainty" =>
                to_string(attrs["certainty"] || attrs[:certainty] || published.certainty),
              "area_desc" => attrs["area_desc"] || attrs[:area_desc] || published.area_desc,
              "geocodes" =>
                attrs["geocodes"] || attrs[:geocodes] || encode_geocodes(published.geocodes)
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
         {:ok, result} <- upsert_from_import(identifier, attrs, fields, actor) do
      {:ok, result}
    end
  end

  defp fetch_identifier(%{identifier: id}) when is_binary(id) and id != "", do: {:ok, id}
  defp fetch_identifier(_), do: {:error, :missing_identifier}

  defp upsert_from_import(identifier, attrs, fields, actor) do
    case get_alert(identifier) do
      nil ->
        create_alert(Map.put(attrs, "identifier", identifier), actor)

      %Alert{} = alert ->
        # Importing an existing alert creates a new draft version based on the
        # latest version (or published version) with the imported content.
        base = latest_version(alert) || published_version(alert)
        number = next_version_number(identifier)

        params =
          version_params(attrs)
          |> Map.merge(%{
            "alert_identifier" => identifier,
            "version_number" => number,
            "workflow_state" => "draft",
            "based_on_version_id" => base && base.id,
            "extensions" => extensions_to_json(fields)
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
                   record_audit(identifier, new_version.id, actor, "imported", %{}) do
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

      with :ok <- assert_latest(alert, locked),
           {:ok, next_state} <- StateMachine.transition(locked.workflow_state, action),
           changeset <-
             change_fun.(locked)
             |> Changeset.put_change(:workflow_state, next_state),
           {:ok, updated} <- Repo.update(changeset),
           {:ok, _audit} <-
             record_audit(alert.identifier, updated.id, actor, Atom.to_string(action), %{}) do
        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp broadcast_on_ok({:ok, %AlertVersion{} = version} = result, message) do
    broadcast_version(version.alert_identifier, {message, version})
    result
  end

  defp broadcast_on_ok(other, _message), do: other

  defp copy_as_new_draft(alert, version, actor) do
    number = next_version_number(alert.identifier)

    params =
      version
      |> version_to_attrs()
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
        "event" => version.event,
        "headline" => version.headline,
        "severity" => version.severity && Atom.to_string(version.severity),
        "urgency" => version.urgency && Atom.to_string(version.urgency),
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
    |> normalize_geocodes()
    |> normalize_extensions()
  end

  defp normalize_keys(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)

  defp normalize_geocodes(%{"geocodes" => list} = params) when is_list(list) do
    encoded =
      Enum.map(list, fn
        %{value_name: _, value: _} = gc -> Map.new(gc, fn {k, v} -> {to_string(k), v} end)
        gc when is_map(gc) -> gc
        {name, value} -> %{"value_name" => name, "value" => value}
      end)

    Map.put(params, "geocodes", encoded)
  end

  defp normalize_geocodes(params), do: params

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

  defp encode_geocodes(geocodes) when is_list(geocodes) do
    Enum.map(geocodes, fn gc -> %{"value_name" => gc.value_name, "value" => gc.value} end)
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
      language: v.language,
      event: v.event,
      headline: v.headline,
      description: v.description,
      instruction: v.instruction,
      urgency: v.urgency,
      severity: v.severity,
      certainty: v.certainty,
      area_desc: v.area_desc,
      geocodes: Enum.map(v.geocodes, fn gc -> %{value_name: gc.value_name, value: gc.value} end),
      alert_extensions: json_to_extensions(v.extensions, "alert"),
      info_extensions: json_to_extensions(v.extensions, "info")
    }
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
    |> Map.put("geocodes", encode_geocodes(v.geocodes))
  end

  defp extensions_to_json(fields) do
    alert_ext = fields[:alert_extensions] || []
    info_ext = fields[:info_extensions] || []

    [
      %{"scope" => "alert", "element" => Enum.map(alert_ext, &CapXml.element_to_map/1)},
      %{"scope" => "info", "element" => Enum.map(info_ext, &CapXml.element_to_map/1)}
    ]
  end

  defp json_to_extensions(nil, _scope), do: []

  defp json_to_extensions(list, scope) when is_list(list) do
    case Enum.find(list, fn item -> item["scope"] == scope end) do
      %{"element" => elements} when is_list(elements) ->
        Enum.map(elements, &CapXml.element_from_map/1)

      _ ->
        []
    end
  end

  defp cap_fields_to_attrs(fields) do
    %{
      "sender" => fields[:sender],
      "sent" => fields[:sent] && parse_sent(fields[:sent]),
      "status" => fields[:status] && Atom.to_string(fields[:status]),
      "msg_type" => fields[:msg_type] && Atom.to_string(fields[:msg_type]),
      "scope" => fields[:scope] && Atom.to_string(fields[:scope]),
      "language" => fields[:language],
      "event" => fields[:event],
      "headline" => fields[:headline],
      "description" => fields[:description],
      "instruction" => fields[:instruction],
      "urgency" => fields[:urgency] && Atom.to_string(fields[:urgency]),
      "severity" => fields[:severity] && Atom.to_string(fields[:severity]),
      "certainty" => fields[:certainty] && Atom.to_string(fields[:certainty]),
      "area_desc" => fields[:area_desc],
      "geocodes" =>
        Enum.map(fields[:geocodes] || [], fn gc ->
          %{"value_name" => gc[:value_name], "value" => gc[:value]}
        end)
    }
  end

  defp parse_sent(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> s
    end
  end

  defp parse_sent(other), do: other

  # Re-export enum helpers for the web layer
  def enums, do: Enums
end
