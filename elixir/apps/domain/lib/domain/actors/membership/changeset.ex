defmodule Domain.Actors.Membership.Changeset do
  use Domain, :changeset

  def group_changeset(account_id, connection, attrs) do
    connection
    |> cast(attrs, ~w[actor_id]a)
    |> validate_required(~w[actor_id]a)
    |> changeset(account_id)
  end

  defp changeset(changeset, account_id) do
    changeset
    |> assoc_constraint(:actor)
    |> assoc_constraint(:group)
    |> assoc_constraint(:account)
    |> put_change(:account_id, account_id)
  end
end
