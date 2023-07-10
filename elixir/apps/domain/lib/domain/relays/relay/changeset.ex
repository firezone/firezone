defmodule Domain.Relays.Relay.Changeset do
  use Domain, :changeset
  alias Domain.Version
  alias Domain.Relays

  @upsert_fields ~w[ipv4 ipv6 port
                    last_seen_user_agent last_seen_remote_ip]a
  @conflict_replace_fields ~w[ipv4 ipv6 port
                              last_seen_user_agent last_seen_remote_ip
                              last_seen_version last_seen_at
                              updated_at]a

  def upsert_conflict_target,
    do: {:unsafe_fragment, ~s/(account_id, COALESCE(ipv4, ipv6)) WHERE deleted_at IS NULL/}

  def upsert_on_conflict, do: {:replace, @conflict_replace_fields}

  def upsert_changeset(%Relays.Token{} = token, attrs) do
    %Relays.Relay{}
    |> cast(attrs, @upsert_fields)
    |> validate_required(~w[last_seen_user_agent last_seen_remote_ip]a)
    |> validate_required_one_of(~w[ipv4 ipv6]a)
    |> validate_number(:port, greater_than_or_equal_to: 1, less_than_or_equal_to: 65_535)
    |> unique_constraint(:ipv4, name: :relays_account_id_ipv4_index)
    |> unique_constraint(:ipv6, name: :relays_account_id_ipv6_index)
    |> put_change(:last_seen_at, DateTime.utc_now())
    |> put_relay_version()
    |> put_change(:account_id, token.account_id)
    |> put_change(:group_id, token.group_id)
    |> put_change(:token_id, token.id)
    |> assoc_constraint(:token)
  end

  def delete_changeset(%Relays.Relay{} = relay) do
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
