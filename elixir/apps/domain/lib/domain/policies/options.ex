defmodule Domain.Policies.Options do
  use Domain, :schema

  @primary_key false
  embedded_schema do
    field :allow_clients_to_bypass, :boolean, default: false
  end
end
