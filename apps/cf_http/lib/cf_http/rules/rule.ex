defmodule CfHttp.Rules.Rule do
  @moduledoc """
  Not really sure what to write here. I'll update this later.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "rules" do
    field :destination, :string
    field :enabled, :boolean, default: false
    field :port, :string
    field :protocol, :string

    belongs_to :device, CfHttp.Devices.Device

    timestamps()
  end

  @doc false
  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [:destination, :port, :protocol, :enabled])
    |> validate_required([:destination, :port, :protocol, :enabled])
  end
end
