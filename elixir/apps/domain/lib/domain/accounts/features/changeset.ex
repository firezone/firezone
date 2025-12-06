defmodule Domain.Accounts.Features.Changeset do
  import Ecto.Changeset
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
