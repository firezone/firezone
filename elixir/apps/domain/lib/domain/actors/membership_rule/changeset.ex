defmodule Domain.Actors.MembershipRule.Changeset do
  use Domain, :changeset
  alias Domain.Actors.MembershipRule

  @fields ~w[operator jsonpath value]a

  def changeset(membership_rule \\ %MembershipRule{}, attrs) do
    membership_rule
    |> cast(attrs, @fields)
    |> validate_rule()
  end

  defp validate_rule(changeset) do
    case fetch_field(changeset, :operator) do
      {_data_or_changes, :all_users} ->
        validate_required(changeset, ~w[operator]a)

      _other ->
        changeset
        |> validate_required(@fields)
        |> validate_format(:jsonpath, ~r/^\$\.(claims|userinfo)\./,
          message: "only $.claims. or $.userinfo. fields are currently supported"
        )
    end
  end
end
