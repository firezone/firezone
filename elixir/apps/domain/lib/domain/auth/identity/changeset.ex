defmodule Domain.Auth.Identity.Changeset do
  use Domain, :changeset
  alias Domain.Actors
  alias Domain.Auth.{Subject, Identity, Provider}

  def create_identity(actor, provider, attrs, %Subject{} = subject) do
    actor
    |> create_identity(provider, attrs)
    |> put_change(:created_by, :identity)
    |> put_change(:created_by_identity_id, subject.identity.id)
  end

  def create_identity(
        %Actors.Actor{account_id: account_id} = actor,
        %Provider{account_id: account_id} = provider,
        attrs
      ) do
    %Identity{}
    |> cast(attrs, ~w[provider_identifier])
    |> validate_required(~w[provider_identifier])
    |> cast_assoc(:actor,
      with: fn _actor, attrs ->
        Actors.Actor.Changeset.actor_changeset(account_id, attrs)
      end
    )
    |> put_change(:actor_id, actor.id)
    |> put_change(:provider_id, provider.id)
    |> put_change(:account_id, account_id)
    |> unique_constraint(:provider_identifier,
      name: :auth_identities_account_id_provider_id_provider_identifier_idx
    )
    |> validate_required(:provider_identifier)
    |> put_change(:created_by, :system)
  end

  def update_identity_provider_state(identity_or_changeset, %{} = state, virtual_state \\ %{}) do
    identity_or_changeset
    |> change()
    |> put_change(:provider_state, state)
    |> put_change(:provider_virtual_state, virtual_state)
  end

  def sign_in_identity(identity_or_changeset, user_agent, remote_ip) do
    identity_or_changeset
    |> change()
    |> put_change(:last_seen_user_agent, user_agent)
    |> put_change(:last_seen_remote_ip, %Postgrex.INET{address: remote_ip})
    |> put_change(:last_seen_at, DateTime.utc_now())
  end

  def delete_identity(%Identity{} = identity) do
    identity
    |> change()
    |> put_change(:provider_state, %{})
    |> put_change(:provider_virtual_state, %{})
    |> put_default_value(:deleted_at, DateTime.utc_now())
  end
end
