defmodule Domain.Actors.Membership.Changeset do
  use Domain, :changeset

  def upsert_conflict_target, do: [:group_id, :actor_id]
  def upsert_on_conflict, do: :nothing

  def changeset(account_id, membership, attrs) do
    membership
    |> cast(attrs, ~w[actor_id group_id]a)
    |> validate_required_one_of(~w[actor_id group_id]a)
    |> assoc_constraint(:actor)
    |> assoc_constraint(:group)
    |> assoc_constraint(:account)
    |> put_change(:account_id, account_id)
  end
end
