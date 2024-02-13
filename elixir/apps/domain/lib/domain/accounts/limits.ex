defmodule Domain.Accounts.Limits do
  use Domain, :schema

  @primary_key false
  embedded_schema do
    field :monthly_active_actors_count, :integer
  end
end
