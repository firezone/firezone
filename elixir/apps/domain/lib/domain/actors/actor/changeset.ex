defmodule Domain.Actors.Actor.Changeset do
  use Domain, :changeset
  alias Domain.Actors

  # TODO: refactor naming for changeset functions
  # TODO: defp
  def create_changeset(attrs) do
    %Actors.Actor{}
    |> cast(attrs, ~w[type name]a)
    |> validate_required(~w[type name]a)
    |> put_change(:account_id, account_id)
  end

  def create_changeset(account_id, attrs) do
    create_changeset(attrs)
    |> put_change(:account_id, account_id)
    |> cast_assoc(:memberships,
      with: &Actors.Membership.Changeset.group_changeset(account_id, &1, &2)
    )
  end

  def update_changeset(actor, attrs) do
    actor
    |> cast(attrs, ~w[type name]a)
    |> validate_required(~w[type name]a)
    |> cast_assoc(:memberships,
      with: &Actors.Membership.Changeset.group_changeset(actor.account_id, &1, &2)
    )
  end

  def disable_actor(actor) do
    actor
    |> change()
    |> put_default_value(:disabled_at, DateTime.utc_now())
  end

  def enable_actor(actor) do
    actor
    |> change()
    |> put_default_value(:disabled_at, nil)
  end

  def delete_actor(actor) do
    actor
    |> change()
    |> put_default_value(:deleted_at, DateTime.utc_now())
  end
end
