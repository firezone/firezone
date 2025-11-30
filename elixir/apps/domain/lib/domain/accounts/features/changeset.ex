defmodule Domain.Accounts.Features.Changeset do
  use Domain, :changeset
  alias Domain.Accounts.Features

  @fields ~w[
    policy_conditions
    multi_site_resources
    traffic_filters
    idp_sync
    rest_api
    internet_resource
  ]a

  def changeset(features \\ %Features{}, attrs) do
    features
    |> cast(attrs, @fields)
  end
end
