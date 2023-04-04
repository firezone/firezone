defmodule Domain.Devices do
  alias Domain.{Repo, Config, Auth, Validator}
  alias Domain.{Users, Telemetry}
  alias Domain.Devices.{Device, Authorizer}

  def count do
    Device.Query.all()
    |> Repo.aggregate(:count)
  end

  def count_by_user_id(user_id) do
    Device.Query.by_user_id(user_id)
    |> Repo.aggregate(:count)
  end

  def count_active_within(duration_in_seconds) when is_integer(duration_in_seconds) do
    Device.Query.by_latest_handshake_seconds_ago(duration_in_seconds)
    |> Repo.aggregate(:count)
  end

  def count_maximum_for_a_user do
    Device.Query.group_by_user_id()
    |> Device.Query.select_max_count()
    |> Repo.one()
  end

  def fetch_device_by_id(id, %Auth.Subject{} = subject) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_devices_permission(),
         Authorizer.view_own_devices_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions),
         true <- Validator.valid_uuid?(id) do
      Device.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch()
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def fetch_device_by_id!(id) do
    Device.Query.by_id(id)
    |> Repo.one!()
  end

  def list_devices(%Auth.Subject{} = subject) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_devices_permission(),
         Authorizer.view_own_devices_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions) do
      Device.Query.all()
      |> Authorizer.for_subject(subject)
      |> Repo.list()
    end
  end

  def list_devices_for_user(%Users.User{} = user, %Auth.Subject{} = subject) do
    list_devices_by_user_id(user.id, subject)
  end

  def list_devices_by_user_id(user_id, %Auth.Subject{} = subject) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_devices_permission(),
         Authorizer.view_own_devices_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions) do
      Device.Query.by_user_id(user_id)
      |> Authorizer.for_subject(subject)
      |> Repo.list()
    end
  end

  def new_device(attrs \\ %{}) do
    Device.Changeset.create_changeset(attrs)
    |> Device.Changeset.configure_changeset(attrs)
  end

  def change_device(%Device{} = device, attrs \\ %{}) do
    Device.Changeset.update_changeset(device, attrs)
    |> Device.Changeset.configure_changeset(attrs)
  end

  def create_device_for_user(%Users.User{} = user, attrs \\ %{}, %Auth.Subject{} = subject) do
    with :ok <- authorize_user_device_management(user.id, subject) do
      changeset = Device.Changeset.create_changeset(user, attrs)

      changeset =
        if authorize_device_configuration(subject) == :ok do
          Device.Changeset.configure_changeset(changeset, attrs)
        else
          changeset
        end

      case Repo.insert(changeset) do
        {:ok, device} ->
          Telemetry.add_device()
          {:ok, device}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  def authorize_device_configuration(subject) do
    Auth.ensure_has_permissions(subject, Authorizer.configure_devices_permission())
  end

  def authorize_user_device_management(%Users.User{} = user, %Auth.Subject{} = subject) do
    authorize_user_device_management(user.id, subject)
  end

  def authorize_user_device_management(user_id, %Auth.Subject{} = subject) do
    required_permissions =
      case subject.actor do
        {:user, %{id: ^user_id}} ->
          Authorizer.manage_own_devices_permission()

        _other ->
          Authorizer.manage_devices_permission()
      end

    Auth.ensure_has_permissions(subject, required_permissions)
  end

  def update_device(%Device{} = device, attrs, %Auth.Subject{} = subject) do
    with :ok <- authorize_user_device_management(device.user_id, subject) do
      device
      |> Device.Changeset.update_changeset(attrs)
      |> Repo.update()
    end
  end

  def update_metrics(%Device{} = device, attrs) do
    device
    |> Device.Changeset.metrics_changeset(attrs)
    |> Repo.update()
  end

  def delete_device(%Device{} = device, %Auth.Subject{} = subject) do
    with :ok <- authorize_user_device_management(device.user_id, subject) do
      Telemetry.delete_device()
      Repo.delete(device)
    end
  end

  def generate_name(name \\ Domain.NameGenerator.generate()) do
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

  def setting_projection(device_or_map) do
    %{
      ip: if(device_or_map.ipv4, do: to_string(device_or_map.ipv4)),
      ip6: if(device_or_map.ipv6, do: to_string(device_or_map.ipv6)),
      user_id: device_or_map.user_id
    }
  end

  def as_settings do
    Device.Query.all()
    |> Repo.all()
    |> Enum.map(&setting_projection/1)
    |> MapSet.new()
  end

  def to_peer_list do
    Device.Query.all()
    |> Device.Query.only_active()
    |> Repo.all()
    |> Enum.map(fn device ->
      %{
        public_key: device.public_key,
        inet: inet(device),
        preshared_key: device.preshared_key
      }
    end)
  end

  def inet(device) do
    ips =
      if Config.fetch_env!(:domain, :wireguard_ipv6_enabled) == true do
        ["#{device.ipv6}/128"]
      else
        []
      end

    ips =
      if Config.fetch_env!(:domain, :wireguard_ipv4_enabled) == true do
        ["#{device.ipv4}/32"] ++ ips
      else
        ips
      end

    Enum.join(ips, ",")
  end

  def get_allowed_ips(device, defaults \\ defaults()), do: config(device, defaults, :allowed_ips)
  def get_endpoint(device, defaults \\ defaults()), do: config(device, defaults, :endpoint)
  def get_dns(device, defaults \\ defaults()), do: config(device, defaults, :dns)
  def get_mtu(device, defaults \\ defaults()), do: config(device, defaults, :mtu)

  def get_persistent_keepalive(device, defaults \\ defaults()),
    do: config(device, defaults, :persistent_keepalive)

  defp config(device, defaults, key) do
    if Map.get(device, String.to_atom("use_default_#{key}")) == true do
      Map.fetch!(defaults, String.to_atom("default_client_#{key}"))
    else
      Map.get(device, key)
    end
  end

  def defaults do
    Config.fetch_configs!([
      :default_client_allowed_ips,
      :default_client_endpoint,
      :default_client_dns,
      :default_client_mtu,
      :default_client_persistent_keepalive
    ])
  end
end
