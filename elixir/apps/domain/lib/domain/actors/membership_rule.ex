defmodule Domain.Actors.MembershipRule do
  use Domain, :schema

  @primary_key false
  embedded_schema do
    # `true` is a special operator which allows to select all account users
    field :operator, Ecto.Enum, values: ~w[true contains does_not_contain is_in is_not_in]a

    field :path, {:array, :string}
    field :values, {:array, :string}
  end
end
