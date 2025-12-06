defmodule Domain.Accounts.Features do
  use Ecto.Schema

  embedded_schema do
    field :policy_conditions, :boolean
    field :multi_site_resources, :boolean
    field :traffic_filters, :boolean
    field :idp_sync, :boolean
    field :rest_api, :boolean
    field :internet_resource, :boolean
  end
end
