defmodule Domain.Gateways.Gateway.Changeset do
  use Domain, :changeset
  alias Domain.Version
  alias Domain.Gateways

  @upsert_fields ~w[external_id name public_key
                    last_seen_user_agent
                    last_seen_remote_ip
                    last_seen_remote_ip_location_region
                    last_seen_remote_ip_location_city
                    last_seen_remote_ip_location_lat
                    last_seen_remote_ip_location_lon]a
  @conflict_replace_fields ~w[public_key
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
  @required_fields ~w[external_id name public_key
                    last_seen_user_agent last_seen_remote_ip]a

  # WireGuard base64-encoded string length
  @key_length 44

  def upsert_conflict_target,
    do: {:unsafe_fragment, ~s/(account_id, group_id, external_id) WHERE deleted_at IS NULL/}

  def upsert_on_conflict, do: {:replace, @conflict_replace_fields}

  def upsert(%Gateways.Token{} = token, attrs) do
    %Gateways.Gateway{}
    |> cast(attrs, @upsert_fields)
    |> put_default_value(:name, fn ->
      Domain.Crypto.random_token(5, encoder: :user_friendly)
    end)
    |> changeset()
    |> validate_required(@required_fields)
    |> validate_base64(:public_key)
    |> validate_length(:public_key, is: @key_length)
    |> unique_constraint(:public_key, name: :gateways_account_id_public_key_index)
    |> unique_constraint(:ipv4)
    |> unique_constraint(:ipv6)
    |> put_change(:last_seen_at, DateTime.utc_now())
    |> put_gateway_version()
    |> put_change(:account_id, token.account_id)
    |> put_change(:group_id, token.group_id)
    |> put_change(:token_id, token.id)
    |> assoc_constraint(:token)
  end

  def finalize_upsert(%Gateways.Gateway{} = gateway, ipv4, ipv6) do
    gateway
    |> change()
    |> put_change(:ipv4, ipv4)
    |> put_change(:ipv6, ipv6)
  end

  def update(%Gateways.Gateway{} = gateway, attrs) do
    gateway
    |> cast(attrs, @update_fields)
    |> changeset()
    |> validate_required(@required_fields)
  end

  def delete(%Gateways.Gateway{} = gateway) do
    gateway
    |> change()
    |> put_default_value(:deleted_at, DateTime.utc_now())
  end

  defp changeset(changeset) do
    changeset
    |> trim_change(:name)
    |> validate_length(:name, min: 1, max: 255)
    |> unique_constraint(:name, name: :gateways_group_id_name_index)
    |> unique_constraint([:public_key])
    |> unique_constraint(:external_id)
  end

  def put_gateway_version(changeset) do
    with {_data_or_changes, user_agent} when not is_nil(user_agent) <-
           fetch_field(changeset, :last_seen_user_agent),
         {:ok, version} <- Version.fetch_version(user_agent) do
      put_change(changeset, :last_seen_version, version)
    else
      {:error, :invalid_user_agent} -> add_error(changeset, :last_seen_user_agent, "is invalid")
      _ -> changeset
    end
  end
end
