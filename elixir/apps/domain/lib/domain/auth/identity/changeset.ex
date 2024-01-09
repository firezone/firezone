defmodule Domain.Auth.Identity.Changeset do
  use Domain, :changeset
  alias Domain.Actors
  alias Domain.Auth.{Subject, Identity, Provider}

  def create_identity(
        %Actors.Actor{} = actor,
        %Provider{} = provider,
        attrs,
        %Subject{} = subject
      ) do
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
    |> cast(attrs, ~w[provider_identifier provider_virtual_state]a)
    |> validate_required(~w[provider_identifier]a)
    |> put_change(:actor_id, actor.id)
    |> put_change(:provider_id, provider.id)
    |> put_change(:account_id, account_id)
    |> put_change(:created_by, :system)
    |> changeset()
  end

  def create_identity_and_actor(
        %Provider{account_id: account_id} = provider,
        attrs
      ) do
    %Identity{}
    |> cast(attrs, ~w[provider_identifier provider_state provider_virtual_state]a)
    |> validate_required(~w[provider_identifier]a)
    |> cast_assoc(:actor,
      with: fn _actor, attrs ->
        Actors.Actor.Changeset.create(account_id, attrs)
        |> put_change(:last_synced_at, DateTime.utc_now())
      end
    )
    |> put_change(:provider_id, provider.id)
    |> put_change(:account_id, account_id)
    |> put_change(:created_by, :provider)
    |> changeset()
  end

  def update_identity_and_actor(%Identity{} = identity, attrs) do
    identity
    |> cast(attrs, ~w[provider_state]a)
    |> cast_assoc(:actor,
      with: fn actor, attrs ->
        Actors.Actor.Changeset.sync(actor, attrs)
      end
    )
    |> changeset()
  end

  def changeset(changeset) do
    changeset
    |> unique_constraint(:provider_identifier,
      name: :auth_identities_account_id_provider_id_provider_identifier_idx
    )
  end

  def update_identity_provider_state(identity_or_changeset, %{} = state, virtual_state \\ %{}) do
    identity_or_changeset
    |> change()
    |> put_change(:provider_state, state)
    |> put_change(:provider_virtual_state, virtual_state)
  end

  def track_identity(identity_or_changeset, context) do
    identity_or_changeset
    |> change()
    |> put_change(:last_seen_user_agent, context.user_agent)
    |> put_change(:last_seen_remote_ip, %Postgrex.INET{address: context.remote_ip})
    |> put_change(:last_seen_remote_ip_location_region, context.remote_ip_location_region)
    |> put_change(:last_seen_remote_ip_location_city, context.remote_ip_location_city)
    |> put_change(:last_seen_remote_ip_location_lat, context.remote_ip_location_lat)
    |> put_change(:last_seen_remote_ip_location_lon, context.remote_ip_location_lon)
    |> put_change(:last_seen_at, DateTime.utc_now())
    |> validate_required(~w[last_seen_user_agent last_seen_remote_ip]a)
  end

  def delete_identity(%Identity{} = identity) do
    identity
    |> change()
    |> put_change(:provider_state, %{})
    |> put_change(:provider_virtual_state, %{})
    |> put_default_value(:deleted_at, DateTime.utc_now())
  end
end
