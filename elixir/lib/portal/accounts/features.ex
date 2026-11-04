defmodule Portal.Accounts.Features do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :policy_conditions, :boolean
    field :idp_sync, :boolean
    field :internet_resource, :boolean
    field :iceless, :boolean
    field :log_sinks, :boolean
    field :device_posture, :boolean
    field :slug_changes, :boolean
  end

  def changeset(features \\ %__MODULE__{}, attrs) do
    fields = ~w[
      policy_conditions
      idp_sync
      internet_resource
      iceless
      log_sinks
      device_posture
      slug_changes
    ]a

    features
    |> cast(attrs, fields)
  end
end
