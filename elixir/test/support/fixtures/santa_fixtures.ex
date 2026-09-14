defmodule Portal.SantaFixtures do
  @moduledoc "Test helpers for creating Santa posture providers and their devices."

  import Portal.DevicePostureFixtures

  def santa_posture_provider_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    account = Map.get(attrs, :account) || device_posture_account_fixture()
    id = Map.get(attrs, :id, Ecto.UUID.generate())
    unique = System.unique_integer([:positive, :monotonic])

    name = Map.get(attrs, :name, "Santa #{unique}")
    parent = posture_provider_fixture(account, id, :santa, name)

    provider_attrs = %{
      id: id,
      account_id: account.id,
      name: name,
      api_url: Map.get(attrs, :api_url, "https://tenant#{unique}.workshop.cloud"),
      api_key: Map.get(attrs, :api_key, "npsws_sk_#{unique}"),
      is_verified: Map.get(attrs, :is_verified, true),
      is_disabled: Map.get(attrs, :is_disabled, false),
      disabled_reason: Map.get(attrs, :disabled_reason),
      synced_at: Map.get(attrs, :synced_at),
      errored_at: Map.get(attrs, :errored_at),
      error_message: Map.get(attrs, :error_message),
      error_email_count: Map.get(attrs, :error_email_count, 0)
    }

    %Portal.Santa.PostureProvider{posture_provider: parent}
    |> Ecto.Changeset.cast(provider_attrs, Map.keys(provider_attrs))
    |> Portal.Santa.PostureProvider.changeset()
    |> Portal.Repo.insert!()
  end

  def santa_device_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    provider = Map.get(attrs, :provider) || santa_posture_provider_fixture(attrs)
    unique = System.unique_integer([:positive, :monotonic])

    device_attrs = %{
      account_id: provider.account_id,
      posture_provider_id: provider.id,
      santa_id: Map.get(attrs, :santa_id, "santa-host-#{unique}"),
      hostname: Map.get(attrs, :hostname, "macbook-#{unique}"),
      serial_number: Map.get(attrs, :serial_number, "SANTA-SERIAL-#{unique}"),
      machine_model: Map.get(attrs, :machine_model, "MacBookPro18,3"),
      os_version: Map.get(attrs, :os_version, "15.6"),
      os_type: Map.get(attrs, :os_type, "OS_TYPE_MACOS"),
      sip_status: Map.get(attrs, :sip_status, 1),
      primary_user: Map.get(attrs, :primary_user, "alice@example.com"),
      santa_version: Map.get(attrs, :santa_version, "2026.7"),
      last_seen_client_mode: Map.get(attrs, :last_seen_client_mode, "LOCKDOWN"),
      last_sync_at: Map.get(attrs, :last_sync_at),
      tags: Map.get(attrs, :tags, ["global"]),
      synced_at:
        Map.get(attrs, :synced_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))
    }

    %Portal.Santa.Device{}
    |> Portal.Santa.Device.changeset(device_attrs)
    |> Portal.Repo.insert!()
  end
end
