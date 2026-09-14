defmodule Portal.DefenderFixtures do
  @moduledoc """
  Test helpers for creating Defender posture providers and their devices.
  """

  import Portal.DevicePostureFixtures

  def defender_posture_provider_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    account = Map.get(attrs, :account) || device_posture_account_fixture()
    id = Map.get(attrs, :id, Ecto.UUID.generate())
    unique = System.unique_integer([:positive, :monotonic])

    name = Map.get(attrs, :name, "Microsoft Defender for Endpoint #{unique}")
    parent = posture_provider_fixture(account, id, :defender, name)

    provider_attrs = %{
      id: id,
      account_id: account.id,
      name: name,
      tenant_id: Map.get(attrs, :tenant_id, Ecto.UUID.generate()),
      is_verified: Map.get(attrs, :is_verified, true),
      is_disabled: Map.get(attrs, :is_disabled, false),
      disabled_reason: Map.get(attrs, :disabled_reason),
      synced_at: Map.get(attrs, :synced_at),
      errored_at: Map.get(attrs, :errored_at),
      error_message: Map.get(attrs, :error_message),
      error_email_count: Map.get(attrs, :error_email_count, 0)
    }

    %Portal.Defender.PostureProvider{posture_provider: parent}
    |> Ecto.Changeset.cast(provider_attrs, Map.keys(provider_attrs))
    |> Portal.Defender.PostureProvider.changeset()
    |> Portal.Repo.insert!()
  end

  def defender_device_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    provider = Map.get(attrs, :provider) || defender_posture_provider_fixture(attrs)
    unique = System.unique_integer([:positive, :monotonic])

    device_attrs = %{
      account_id: provider.account_id,
      posture_provider_id: provider.id,
      defender_id: Map.get(attrs, :defender_id, Ecto.UUID.generate()),
      computer_dns_name: Map.get(attrs, :computer_dns_name, "machine#{unique}.contoso.com"),
      entra_device_id: Map.get(attrs, :entra_device_id, Ecto.UUID.generate()),
      entra_joined: Map.get(attrs, :entra_joined, true),
      machine_tags: Map.get(attrs, :machine_tags),
      os_platform: Map.get(attrs, :os_platform, "Windows11"),
      version: Map.get(attrs, :version, "23H2"),
      os_build: Map.get(attrs, :os_build, 22_631),
      os_architecture: Map.get(attrs, :os_architecture, "64-bit"),
      last_ip_address: Map.get(attrs, :last_ip_address),
      last_external_ip_address: Map.get(attrs, :last_external_ip_address),
      agent_version: Map.get(attrs, :agent_version, "10.8040.19041.4046"),
      health_status: Map.get(attrs, :health_status, "Active"),
      onboarding_status: Map.get(attrs, :onboarding_status, "Onboarded"),
      risk_score: Map.get(attrs, :risk_score, "Low"),
      exposure_level: Map.get(attrs, :exposure_level, "Low"),
      device_value: Map.get(attrs, :device_value, "Normal"),
      rbac_group_id: Map.get(attrs, :rbac_group_id),
      rbac_group_name: Map.get(attrs, :rbac_group_name),
      ip_addresses: Map.get(attrs, :ip_addresses),
      first_seen_at: Map.get(attrs, :first_seen_at),
      last_seen_at: Map.get(attrs, :last_seen_at),
      synced_at:
        Map.get(attrs, :synced_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))
    }

    %Portal.Defender.Device{}
    |> Portal.Defender.Device.changeset(device_attrs)
    |> Portal.Repo.insert!()
  end
end
