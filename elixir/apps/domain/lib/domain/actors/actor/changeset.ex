defmodule Domain.Actors.Actor.Changeset do
  use Domain, :changeset
  alias Domain.Actors

  def changeset(actor, attrs) do
    actor
    |> cast(attrs, ~w[type name]a)
    |> validate_required(~w[type name]a)
    |> validate_length(:name, min: 1, max: 255)
  end

  def create_changeset(account_id, attrs) do
    %Actors.Actor{}
    |> changeset(attrs)
    |> put_change(:account_id, account_id)
  end

  def set_actor_type(actor, type) do
    actor
    |> change()
    |> put_change(:type, type)
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
