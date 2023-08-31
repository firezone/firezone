defmodule Domain.Actors.Actor.Changeset do
  use Domain, :changeset
  alias Domain.Actors
  alias Domain.Actors.Actor

  def keys, do: ~w[type name]a
  def keys(%Actor{last_synced_at: nil}), do: ~w[type name]a
  def keys(%Actor{}), do: ~w[type]a

  def create(attrs) do
    keys = keys()

    %Actors.Actor{memberships: []}
    |> cast(attrs, keys)
    |> validate_required(keys)
    |> changeset()
  end

  def create(account_id, attrs) do
    create(attrs)
    |> put_change(:account_id, account_id)
    |> cast_assoc(:memberships,
      with: &Actors.Membership.Changeset.changeset(account_id, &1, &2)
    )
  end

  def update(%Actor{} = actor, attrs) do
    keys = keys(actor)

    actor
    |> cast(attrs, keys)
    |> validate_required(keys)
    |> cast_assoc(:memberships,
      with: &Actors.Membership.Changeset.changeset(actor.account_id, &1, &2)
    )
    |> changeset()
  end

  def changeset(changeset) do
    changeset
    # Actor name can be very long in case IdP syncs something crazy long to us,
    # we still don't wait to fail for that silently
    |> validate_length(:name, max: 512)
  end

  def disable_actor(%Actor{} = actor) do
    actor
    |> change()
    |> put_default_value(:disabled_at, DateTime.utc_now())
  end

  def enable_actor(%Actor{} = actor) do
    actor
    |> change()
    |> put_change(:disabled_at, nil)
  end

  def delete_actor(%Actor{} = actor) do
    actor
    |> change()
    |> put_default_value(:deleted_at, DateTime.utc_now())
  end
end
