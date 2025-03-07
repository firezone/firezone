defmodule Domain.Auth.Adapters.Mock.Settings do
  use Domain, :schema

  @primary_key false
  embedded_schema do
    # Number of actors to generate
    field :num_actors, :integer, default: 500

    # Number of groups to generate
    field :num_groups, :integer, default: 2_500

    # Max number of actors per group; will determine the number of memberships
    field :max_actors_per_group, :integer, default: 25
  end
end
