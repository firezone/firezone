defmodule Domain.Actors.Membership.Changeset do
  use Domain, :changeset

  def upsert_conflict_target, do: [:group_id, :actor_id]
  def upsert_on_conflict, do: :nothing

  def for_actor(account_id, membership, attrs) do
    membership
    |> cast(attrs, ~w[group_id last_synced_at]a)
    |> validate_required(~w[group_id]a)
    |> changeset(account_id)
  end

  def for_group(account_id, membership, attrs) do
    membership
    |> cast(attrs, ~w[actor_id last_synced_at]a)
    |> validate_required(~w[actor_id]a)
    |> changeset(account_id)
  end

  def upsert(account_id, membership, attrs) do
    membership
    |> cast(attrs, ~w[actor_id group_id last_synced_at]a)
    |> validate_required_one_of(~w[actor_id group_id]a)
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
