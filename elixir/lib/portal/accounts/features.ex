defmodule Portal.Accounts.Features do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :policy_conditions, :boolean
    field :multi_site_resources, :boolean
    field :traffic_filters, :boolean
    field :idp_sync, :boolean
    field :rest_api, :boolean
    field :internet_resource, :boolean
  end

  def changeset(features \\ %__MODULE__{}, attrs) do
    fields = ~w[
      policy_conditions
      multi_site_resources
      traffic_filters
      idp_sync
      rest_api
      internet_resource
    ]a

    features
    |> cast(attrs, fields)
  end
end
