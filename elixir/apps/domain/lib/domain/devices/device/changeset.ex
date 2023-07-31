defmodule Domain.Devices.Device.Changeset do
  use Domain, :changeset
  alias Domain.{Version, Auth}
  alias Domain.Devices

  @upsert_fields ~w[external_id name public_key]a
  @conflict_replace_fields ~w[public_key
                              last_seen_user_agent last_seen_remote_ip
                              last_seen_version last_seen_at
                              updated_at]a
  @update_fields ~w[name]a
  @required_fields @upsert_fields

  # WireGuard base64-encoded string length
  @key_length 44

  def upsert_conflict_target,
    do: {:unsafe_fragment, ~s/(account_id, actor_id, external_id) WHERE deleted_at IS NULL/}

  def upsert_on_conflict, do: {:replace, @conflict_replace_fields}

  def upsert_changeset(%Auth.Identity{} = identity, %Auth.Context{} = context, attrs) do
    %Devices.Device{}
    |> cast(attrs, @upsert_fields)
    |> put_default_value(:name, &generate_name/0)
    |> put_change(:identity_id, identity.id)
    |> put_change(:actor_id, identity.actor_id)
    |> put_change(:account_id, identity.account_id)
    |> put_change(:last_seen_user_agent, context.user_agent)
    |> put_change(:last_seen_remote_ip, %Postgrex.INET{address: context.remote_ip})
    |> changeset()
    |> validate_required(@required_fields)
    |> validate_base64(:public_key)
    |> validate_length(:public_key, is: @key_length)
    |> unique_constraint(:ipv4, name: :devices_account_id_ipv4_index)
    |> unique_constraint(:ipv6, name: :devices_account_id_ipv6_index)
    |> put_change(:last_seen_at, DateTime.utc_now())
    |> put_device_version()
  end

  def finalize_upsert_changeset(%Devices.Device{} = device, ipv4, ipv6) do
    device
    |> change()
    |> put_change(:ipv4, ipv4)
    |> put_change(:ipv6, ipv6)
    |> unique_constraint(:ipv4, name: :devices_account_id_ipv4_index)
    |> unique_constraint(:ipv6, name: :devices_account_id_ipv6_index)
  end

  def update_changeset(%Devices.Device{} = device, attrs) do
    device
    |> cast(attrs, @update_fields)
    |> changeset()
    |> validate_required(@required_fields)
  end

  def delete_changeset(%Devices.Device{} = device) do
    device
    |> change()
    |> put_default_value(:deleted_at, DateTime.utc_now())
  end

  defp changeset(changeset) do
    changeset
    |> trim_change(:name)
    |> validate_length(:name, min: 1, max: 255)
    |> assoc_constraint(:actor)
    |> unique_constraint([:actor_id, :name])
    |> unique_constraint([:actor_id, :public_key])
    |> unique_constraint(:external_id)
  end

  defp put_device_version(changeset) do
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
