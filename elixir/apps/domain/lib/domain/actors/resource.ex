defmodule Domain.Actors.Resource do
  @moduledoc """
    Provides a join table to function as a consistent view of which actors potentially
    have access to which resources. This table should be updated whenever:

    - A membership is created or deleted
    - A policy is updated, created, enabled, deleted, or disabled

    Cascading deletes is enabled for the references so that deletetion of any actor, resource, or
    associated account will clean up the join table.
  """
  use Domain, :schema

  @primary_key false
  schema "actor_resources" do
    belongs_to :account, Domain.Accounts.Account, primary_key: true
    belongs_to :actor, Domain.Actors.Actor, primary_key: true
    belongs_to :resource, Domain.Resources.Resource, primary_key: true

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
