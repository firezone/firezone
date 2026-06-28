defmodule Portal.FlowLogFixtures do
  @moduledoc """
  Test helpers for flow log ingest tokens.
  """

  @doc """
  Generate the attribution claims an ingest token carries, with sensible
  defaults. These are the fields the portal snapshots into the JWT and treats
  as authoritative for attribution at ingest.
  """
  def flow_log_token_claims(overrides \\ %{}) do
    Map.merge(
      %{
        "role" => "initiator",
        "device_id" => Ecto.UUID.generate(),
        "policy_authorization_id" => Ecto.UUID.generate(),
        "policy_id" => Ecto.UUID.generate(),
        "resource_id" => Ecto.UUID.generate(),
        "resource_name" => "prod-db",
        "resource_address" => "10.0.0.5",
        "actor_id" => Ecto.UUID.generate(),
        "actor_email" => "user@example.com",
        "actor_name" => "Some User",
        "auth_provider_id" => Ecto.UUID.generate(),
        "authorized_at" => "2026-03-20T09:59:00.000000Z",
        "authorization_expires_at" => "2026-03-20T19:59:00.000000Z",
        "client_version" => "1.4.0",
        "device_os_name" => "iOS",
        "device_os_version" => "17.4",
        "device_serial" => "C02ABC123",
        "device_uuid" => Ecto.UUID.generate(),
        "device_identifier_for_vendor" => Ecto.UUID.generate(),
        "device_firebase_installation_id" => "fId-abc123"
      },
      overrides
    )
  end
end
