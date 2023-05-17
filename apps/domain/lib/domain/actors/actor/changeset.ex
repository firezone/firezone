defmodule Domain.Actors.Actor.Changeset do
  use Domain, :changeset
  alias Domain.Auth
  alias Domain.Actors

  def create_changeset(%Auth.Provider{} = provider, attrs) do
    %Actors.Actor{}
    |> cast(attrs, ~w[type role]a)
    |> validate_required(~w[type role]a)
    |> put_change(:account_id, provider.account_id)
  end

  def set_actor_role(actor, role) do
    actor
    |> change()
    |> put_change(:role, role)
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
