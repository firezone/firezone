defmodule Domain.Clients.Client.Changeset do
  use Domain, :changeset
  alias Domain.{Version, Auth, Actors}
  alias Domain.Clients

  @upsert_fields ~w[external_id last_used_token_id name public_key]a
  @conflict_replace_fields ~w[name
                              public_key
                              last_used_token_id
                              last_seen_user_agent
                              last_seen_remote_ip
                              last_seen_remote_ip_location_region
                              last_seen_remote_ip_location_city
                              last_seen_remote_ip_location_lat
                              last_seen_remote_ip_location_lon
                              last_seen_version
                              last_seen_at
                              updated_at]a
  @update_fields ~w[name]a
  @required_fields @upsert_fields

  # WireGuard base64-encoded string length
  @key_length 44

  def upsert_conflict_target,
    do: {:unsafe_fragment, ~s/(account_id, actor_id, external_id) WHERE deleted_at IS NULL/}

  def upsert_on_conflict, do: {:replace, @conflict_replace_fields}

  def upsert(actor_or_identity, %Auth.Subject{} = subject, attrs) do
    %Clients.Client{}
    |> cast(attrs, @upsert_fields)
    |> put_default_value(:name, &generate_name/0)
    |> put_assocs(actor_or_identity)
    |> put_change(:last_used_token_id, subject.token_id)
    |> put_change(:last_seen_user_agent, subject.context.user_agent)
    |> put_change(:last_seen_remote_ip, %Postgrex.INET{address: subject.context.remote_ip})
    |> put_change(:last_seen_remote_ip_location_region, subject.context.remote_ip_location_region)
    |> put_change(:last_seen_remote_ip_location_city, subject.context.remote_ip_location_city)
    |> put_change(:last_seen_remote_ip_location_lat, subject.context.remote_ip_location_lat)
    |> put_change(:last_seen_remote_ip_location_lon, subject.context.remote_ip_location_lon)
    |> changeset()
    |> validate_required(@required_fields)
    |> validate_base64(:public_key)
    |> validate_length(:public_key, is: @key_length)
    |> unique_constraint(:ipv4, name: :clients_account_id_ipv4_index)
    |> unique_constraint(:ipv6, name: :clients_account_id_ipv6_index)
    |> put_change(:last_seen_at, DateTime.utc_now())
    |> put_client_version()
  end

  defp put_assocs(changeset, %Auth.Identity{} = identity) do
    changeset
    |> put_change(:identity_id, identity.id)
    |> put_change(:actor_id, identity.actor_id)
    |> put_change(:account_id, identity.account_id)
  end

  defp put_assocs(changeset, %Actors.Actor{} = actor) do
    changeset
    |> put_change(:actor_id, actor.id)
    |> put_change(:account_id, actor.account_id)
  end

  def finalize_upsert(%Clients.Client{} = client, ipv4, ipv6) do
    client
    |> change()
    |> put_change(:ipv4, ipv4)
    |> put_change(:ipv6, ipv6)
    |> unique_constraint(:ipv4, name: :clients_account_id_ipv4_index)
    |> unique_constraint(:ipv6, name: :clients_account_id_ipv6_index)
  end

  def update(%Clients.Client{} = client, attrs) do
    client
    |> cast(attrs, @update_fields)
    |> validate_required(@required_fields)
    |> changeset()
  end

  defp changeset(changeset) do
    changeset
    |> trim_change(:name)
    |> validate_length(:name, min: 1, max: 255)
    |> assoc_constraint(:actor)
    |> unique_constraint([:actor_id, :public_key])
    |> unique_constraint(:external_id)
  end

  defp put_client_version(changeset) do
    with {_data_or_changes, user_agent} when not is_nil(user_agent) <-
           fetch_field(changeset, :last_seen_user_agent),
         {:ok, version} <- Version.fetch_version(user_agent) do
      put_change(changeset, :last_seen_version, version)
    else
      {:error, :invalid_user_agent} -> add_error(changeset, :last_seen_user_agent, "is invalid")
      _ -> changeset
    end
  end

  defp generate_name do
    name = Domain.NameGenerator.generate()

    hash =
      name
      |> :erlang.phash2(2 ** 16)
      |> Integer.to_string(16)
      |> String.pad_leading(4, "0")

    if String.length(name) > 15 do
      String.slice(name, 0..10) <> hash
    else
      name
    end
  end
end
