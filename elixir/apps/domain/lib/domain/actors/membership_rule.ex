defmodule Domain.Actors.MembershipRule do
  use Domain, :schema

  @primary_key false
  embedded_schema do
    field :operator, Ecto.Enum,
      values: ~w[all_users equals_to does_not_equal_to contains does_not_contain is_in is_not_in]a

    field :jsonpath, :string
    field :value, :string
  end
end
