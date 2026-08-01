defmodule CapWorkbench.Cap.AlertMessage do
  @moduledoc """
  The stable CAP envelope + editorial workflow aggregate root.

  The `identifier`, `sender`, `references`, and area identity are stable for the
  life of the message. `workflow_state` is only ever changed through the domain
  state machine (`CapWorkbench.Cap.StateMachine`) and the context use-cases;
  callers outside the domain must never write to it directly.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias CapWorkbench.Cap.Enums

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "alert_messages" do
    field :identifier, :string
    field :sender, :string
    field :sent_at, :utc_datetime_usec

    field :status, Ecto.Enum, values: Enums.statuses()
    field :msg_type, Ecto.Enum, values: Enums.msg_types()
    field :scope, Ecto.Enum, values: Enums.scopes()

    field :workflow_state, Ecto.Enum, values: Enums.workflow_states(), default: :drafting

    field :references_text, :string
    field :published_version_id, :binary_id

    # Optimistic lock over the aggregate's workflow-level transitions.
    field :lock_version, :integer, default: 1

    belongs_to :references_message, __MODULE__
    has_many :versions, CapWorkbench.Cap.DraftVersion

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for creating the immutable identity fields of a message.

  `workflow_state`, `published_version_id`, and `lock_version` are deliberately
  excluded from user-facing casts and are set explicitly by the domain.
  """
  def create_changeset(message, attrs) do
    message
    |> cast(attrs, [
      :identifier,
      :sender,
      :sent_at,
      :status,
      :msg_type,
      :scope,
      :references_text,
      :references_message_id
    ])
    |> validate_required([:identifier, :sender, :sent_at, :status, :msg_type, :scope])
    |> unique_constraint(:identifier)
    |> foreign_key_constraint(:references_message_id)
  end
end
