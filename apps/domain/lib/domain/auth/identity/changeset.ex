defmodule Domain.Auth.Identity.Changeset do
  use Domain, :changeset
  alias Domain.Actors
  alias Domain.Auth.{Adapters, Identity, Provider}

  def create(
        %Actors.Actor{account_id: account_id} = actor,
        %Provider{account_id: account_id} = provider,
        provider_identifier
      ) do
    {provider_state, provider_virtual_state} = Adapters.identity_create_state(provider)

    %Identity{}
    |> change()
    |> put_change(:actor_id, actor.id)
    |> put_change(:provider_id, provider.id)
    |> put_change(:account_id, account_id)
    |> put_change(:provider_identifier, provider_identifier)
    |> put_change(:provider_state, provider_state)
    |> put_change(:provider_virtual_state, provider_virtual_state)
    |> unique_constraint(:provider_identifier,
      name: :auth_identities_provider_id_provider_identifier_index
    )
  end

  def update_provider_state(identity_or_changeset, %{} = state, virtual_state \\ %{}) do
    identity_or_changeset
    |> change()
    |> put_change(:provider_state, state)
    |> put_change(:provider_virtual_state, virtual_state)
  end

  def sign_in(identity_or_changeset, user_agent, remote_ip) do
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
    |> put_change(:deleted_at, DateTime.utc_now())
  end

  # test "returns error when provider identifier is already taken", %{
  #   account: account,
  #   provider: provider,
  #   provider_identifier: provider_identifier
  # } do
  #   attrs = ActorsFixtures.actor_attrs(role: :unprivileged)
  #   assert {:ok, _actor} = create_actor(account, provider, provider_identifier, attrs)
  #   assert {:error, changeset} = create_actor(account, provider, provider_identifier, attrs)
  #   refute changeset.valid?
  #   assert "has already been taken" in errors_on(changeset).provider_identifier
  # end
end
