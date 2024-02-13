defmodule Domain.Accounts.Limits.Changeset do
  use Domain, :changeset
  alias Domain.Accounts.Limits

  @fields ~w[monthly_active_actors_count]a

  def changeset(limits \\ %Limits{}, attrs) do
    limits
    |> cast(attrs, @fields)
    |> validate_number(:monthly_active_actors_count,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 999_999
    )
  end
end
