defmodule Portal.SentinelOneFixtures do
  @moduledoc "Test helpers for SentinelOne posture providers and devices."

  import Portal.DevicePostureFixtures

  def sentinelone_posture_provider_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    account = Map.get(attrs, :account) || device_posture_account_fixture()
    id = Map.get(attrs, :id, Ecto.UUID.generate())
    unique = System.unique_integer([:positive, :monotonic])

    name = Map.get(attrs, :name, "SentinelOne #{unique}")
    parent = posture_provider_fixture(account, id, :sentinelone, name)

    provider_attrs = %{
      id: id,
      account_id: account.id,
      name: name,
      management_url:
        Map.get(attrs, :management_url, "https://tenant-#{unique}.sentinelone.net"),
      api_token: Map.get(attrs, :api_token, "sentinelone-test-api-token-#{unique}"),
      is_verified: Map.get(attrs, :is_verified, true),
      is_disabled: Map.get(attrs, :is_disabled, false),
      disabled_reason: Map.get(attrs, :disabled_reason),
      synced_at: Map.get(attrs, :synced_at),
      errored_at: Map.get(attrs, :errored_at),
      error_message: Map.get(attrs, :error_message),
      error_email_count: Map.get(attrs, :error_email_count, 0)
    }

    %Portal.SentinelOne.PostureProvider{posture_provider: parent}
    |> Ecto.Changeset.cast(provider_attrs, Map.keys(provider_attrs))
    |> Portal.SentinelOne.PostureProvider.changeset()
    |> Portal.Repo.insert!()
  end

  def sentinelone_device_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    provider = Map.get(attrs, :provider) || sentinelone_posture_provider_fixture(attrs)
    unique = System.unique_integer([:positive, :monotonic])

    device_attrs = %{
      account_id: provider.account_id,
      posture_provider_id: provider.id,
      sentinelone_id: Map.get(attrs, :sentinelone_id, Integer.to_string(unique)),
      uuid: Map.get(attrs, :uuid, Ecto.UUID.generate()),
      computer_name: Map.get(attrs, :computer_name, "endpoint-#{unique}"),
      serial_number: Map.get(attrs, :serial_number, "S1-SERIAL-#{unique}"),
      os_name: Map.get(attrs, :os_name, "Windows 11"),
      os_type: Map.get(attrs, :os_type, "windows"),
      agent_version: Map.get(attrs, :agent_version, "24.1.4.257"),
      is_active: Map.get(attrs, :is_active, true),
      infected: Map.get(attrs, :infected, false),
      synced_at:
        Map.get(attrs, :synced_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))
    }

    %Portal.SentinelOne.Device{}
    |> Portal.SentinelOne.Device.changeset(device_attrs)
    |> Portal.Repo.insert!()
  end
end
