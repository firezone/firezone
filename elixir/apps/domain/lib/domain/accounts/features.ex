defmodule Domain.Accounts.Features do
  use Domain, :schema

  @primary_key false
  embedded_schema do
    field :flow_activities, :boolean
    field :multi_site_resources, :boolean
    field :traffic_filters, :boolean
    field :self_hosted_relays, :boolean
    field :idp_sync, :boolean
  end
end
