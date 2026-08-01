defmodule CapAlertWorkbench.CapAlert.Geocode do
  @moduledoc "An embedded CAP geocode entry (valueName/value pair)."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :value_name, :string
    field :value, :string
  end

  def changeset(geocode, attrs) do
    geocode
    |> cast(attrs, [:value_name, :value])
    |> validate_required([:value_name, :value])
  end
end
