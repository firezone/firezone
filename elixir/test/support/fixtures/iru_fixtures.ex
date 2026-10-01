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

  @doc "Build a iru API response payload for sync tests."
  def iru_api_device_fixture(overrides \\ %{}) do
    Map.merge(
      %{
        "device_id" => "device-1",
        "device_name" => "Alice's MacBook Air",
        "model" => "MacBook Air (M1, 2020)",
        "serial_number" => "FVHHFKF7Q6L4",
        "platform" => "Mac",
        "os_version" => "14.4.1",
        "supplemental_build_version" => "23E224",
        "supplemental_os_version_extra" => "",
        "last_check_in" => "2024-07-23T14:11:37.150080Z",
        "user" => %{
          "email" => "accuhive.admin@kandji.io",
          "name" => "Accuhive Admin",
          "id" => "5344c996-8823-4b37-8d6e-8515fc7c3a0a",
          "is_archived" => false
        },
        "asset_tag" => "",
        "blueprint_id" => "ab102b9d-8e9c-420d-a498-f2a1123091c7",
        "blueprint_name" => "main hive",
        "mdm_enabled" => true,
        "agent_installed" => true,
        "is_missing" => false,
        "is_removed" => false,
        "agent_version" => "4.5.9 (5160)",
        "first_enrollment" => "2024-01-26 16:15:36.087016+00:00",
        "last_enrollment" => "2024-05-13 20:09:27.374451+00:00",
        "lost_mode_status" => "",
        "tags" => ["accuhive_02"]
      },
      Enum.into(overrides, %{})
    )
  end
end
