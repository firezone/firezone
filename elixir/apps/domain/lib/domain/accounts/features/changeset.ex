defmodule Domain.Accounts.Features.Changeset do
  use Domain, :changeset
  alias Domain.Accounts.Features

  @fields ~w[
    flow_activities
    policy_conditions
    multi_site_resources
    traffic_filters
    self_hosted_relays
    idp_sync
    rest_api
  ]a

  def changeset(features \\ %Features{}, attrs) do
    features
    |> cast(attrs, @fields)
  end
end
