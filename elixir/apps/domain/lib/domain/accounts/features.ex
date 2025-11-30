defmodule Domain.Accounts.Features do
  use Domain, :schema

  @primary_key false
  embedded_schema do
    field :policy_conditions, :boolean
    field :multi_site_resources, :boolean
    field :traffic_filters, :boolean
    field :idp_sync, :boolean
    field :rest_api, :boolean
    field :internet_resource, :boolean
  end
end
