defmodule Domain.Relays.Relay.Changeset do
  use Domain, :changeset
  alias Domain.{Version, Auth}
  alias Domain.Relays

  @upsert_fields ~w[ipv4 ipv6 port name
                    last_seen_user_agent
                    last_seen_remote_ip
                    last_seen_remote_ip_location_region
                    last_seen_remote_ip_location_city
                    last_seen_remote_ip_location_lat
                    last_seen_remote_ip_location_lon]a
  @conflict_replace_fields ~w[ipv4 ipv6 port name
                              last_seen_user_agent
                              last_seen_remote_ip
                              last_seen_remote_ip_location_region
                              last_seen_remote_ip_location_city
                              last_seen_remote_ip_location_lat
                              last_seen_remote_ip_location_lon
                              last_seen_version
                              last_seen_at
                              updated_at]a

  def upsert_conflict_target(%{account_id: nil}) do
    {:unsafe_fragment, ~s/(COALESCE(ipv4, ipv6)) WHERE deleted_at IS NULL AND account_id IS NULL/}
  end

  def upsert_conflict_target(%{account_id: _account_id}) do
    {:unsafe_fragment,
     ~s/(account_id, COALESCE(ipv4, ipv6)) WHERE deleted_at IS NULL AND account_id IS NOT NULL/}
  end

  def upsert_on_conflict, do: {:replace, @conflict_replace_fields}

  def upsert(%Relays.Group{} = group, attrs, %Auth.Context{} = context) do
    %Relays.Relay{}
    |> cast(attrs, @upsert_fields)
    |> validate_required_one_of(~w[ipv4 ipv6]a)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_number(:port, greater_than_or_equal_to: 1, less_than_or_equal_to: 65_535)
    |> unique_constraint(:ipv4, name: :relays_unique_address_index)
    |> unique_constraint(:ipv6, name: :relays_unique_address_index)
    |> unique_constraint(:ipv4, name: :global_relays_unique_address_index)
    |> unique_constraint(:ipv6, name: :global_relays_unique_address_index)
    |> put_change(:last_seen_at, DateTime.utc_now())
    |> put_change(:last_seen_user_agent, context.user_agent)
    |> put_change(:last_seen_remote_ip, context.remote_ip)
    |> put_change(:last_seen_remote_ip_location_region, context.remote_ip_location_region)
    |> put_change(:last_seen_remote_ip_location_city, context.remote_ip_location_city)
    |> put_change(:last_seen_remote_ip_location_lat, context.remote_ip_location_lat)
    |> put_change(:last_seen_remote_ip_location_lon, context.remote_ip_location_lon)
    |> put_relay_version()
    |> put_change(:account_id, group.account_id)
    |> put_change(:group_id, group.id)
  end

  def delete(%Relays.Relay{} = relay) do
    relay
    |> change()
    |> put_default_value(:deleted_at, DateTime.utc_now())
  end

  def put_relay_version(changeset) do
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
