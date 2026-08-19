defmodule Portal.IruFixtures do
  @moduledoc """
  Test helpers for creating Iru posture providers and their devices.
  """

  import Portal.DevicePostureFixtures

  def iru_posture_provider_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    account = Map.get(attrs, :account) || device_posture_account_fixture()
    id = Map.get(attrs, :id, Ecto.UUID.generate())
    unique = System.unique_integer([:positive, :monotonic])

    name = Map.get(attrs, :name, "Iru #{unique}")
    parent = posture_provider_fixture(account, id, :iru, name)

    provider_attrs = %{
      id: id,
      account_id: account.id,
      name: name,
      subdomain: Map.get(attrs, :subdomain, "acme#{unique}"),
      region: Map.get(attrs, :region, :us),
      api_token: Map.get(attrs, :api_token, "iru-token-#{unique}"),
      is_verified: Map.get(attrs, :is_verified, true),
      is_disabled: Map.get(attrs, :is_disabled, false),
      disabled_reason: Map.get(attrs, :disabled_reason),
      synced_at: Map.get(attrs, :synced_at),
      errored_at: Map.get(attrs, :errored_at),
      error_message: Map.get(attrs, :error_message),
      error_email_count: Map.get(attrs, :error_email_count, 0)
    }

    %Portal.Iru.PostureProvider{posture_provider: parent}
    |> Ecto.Changeset.cast(provider_attrs, Map.keys(provider_attrs))
    |> Portal.Iru.PostureProvider.changeset()
    |> Portal.Repo.insert!()
  end

  def iru_device_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    provider = Map.get(attrs, :provider) || iru_posture_provider_fixture(attrs)
    unique = System.unique_integer([:positive, :monotonic])

    device_attrs = %{
      account_id: provider.account_id,
      posture_provider_id: provider.id,
      iru_id: Map.get(attrs, :iru_id, Ecto.UUID.generate()),
      device_name: Map.get(attrs, :device_name, "Inventory Device #{unique}"),
      serial_number: Map.get(attrs, :serial_number, "IRU-SERIAL-#{unique}"),
      platform: Map.get(attrs, :platform, "Mac"),
      model: Map.get(attrs, :model, "MacBook Air (M1, 2020)"),
      os_version: Map.get(attrs, :os_version, "14.4.1"),
      user_email: Map.get(attrs, :user_email),
      user_name: Map.get(attrs, :user_name),
      blueprint_name: Map.get(attrs, :blueprint_name),
      mdm_enabled: Map.get(attrs, :mdm_enabled, true),
      agent_installed: Map.get(attrs, :agent_installed, true),
      is_missing: Map.get(attrs, :is_missing, false),
      is_removed: Map.get(attrs, :is_removed, false),
      last_check_in_at: Map.get(attrs, :last_check_in_at),
      filevault_enabled: Map.get(attrs, :filevault_enabled, true),
      sip_enabled: Map.get(attrs, :sip_enabled),
      firewall_enabled: Map.get(attrs, :firewall_enabled),
      synced_at:
        Map.get(attrs, :synced_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))
    }

    %Portal.Iru.Device{}
    |> Portal.Iru.Device.changeset(device_attrs)
    |> Portal.Repo.insert!()
  end
end
