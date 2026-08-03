defmodule CapAlertWorkbench.CapAlert.Alert do
  @moduledoc "The alert aggregate root, identified by a stable CAP identifier."
  use Ecto.Schema
  import Ecto.Changeset

  alias CapAlertWorkbench.CapAlert.Enums

  @primary_key {:identifier, :string, autogenerate: false}
  @foreign_key_type :string

  schema "alerts" do
    field :sender, :string
    field :latest_version_id, :integer
    field :published_version_id, :integer
    field :state, Ecto.Enum, values: Enums.alert_states(), default: :active

    has_many :versions, CapAlertWorkbench.CapAlert.AlertVersion,
      foreign_key: :alert_identifier,
      references: :identifier

    timestamps(type: :utc_datetime)
  end

  def changeset(alert, attrs) do
    alert
    |> cast(attrs, [:identifier, :sender, :latest_version_id, :published_version_id, :state])
    |> validate_required([:identifier, :sender, :state])
    |> validate_format(:identifier, ~r/^[A-Za-z0-9\-_:.]+$/, message: "只能包含字母、数字、连字符、下划线、冒号和点")
    |> unique_constraint(:identifier, name: :alerts_pkey, message: "该标识已存在")
  end
end
