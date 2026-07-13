defmodule Portal.FlowLogFixtures do
  @moduledoc """
  Test helpers for flow logs and flow log ingest tokens.
  """

  import Portal.AccountFixtures

  alias Portal.FlowLog
  alias Portal.Repo
  alias Portal.Types.LogId

  @doc """
  Insert a flow_log row directly, with sensible defaults for every NOT NULL
  column. Accepts an `:account` (a fresh one is created when omitted) and any
  schema field as an override.
  """
  def flow_log_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    account = Map.get(attrs, :account) || account_fixture()
    now = DateTime.utc_now()

    row =
      attrs
      |> Map.drop([:account])
      |> Map.put_new(:account_id, account.id)
      |> Map.put_new(:log_id, LogId.build_flow_log())
      |> Map.put_new(:device_id, Ecto.UUID.generate())
      |> Map.put_new(:role, :responder)
      |> Map.put_new(:protocol, :tcp)
      |> Map.put_new(:flow_start, DateTime.add(now, -60, :second))
      |> Map.put_new(:flow_end, DateTime.add(now, -30, :second))
      |> Map.put_new(:last_packet, DateTime.add(now, -30, :second))
      |> Map.put_new(:policy_id, Ecto.UUID.generate())
      |> Map.put_new(:policy_authorization_id, Ecto.UUID.generate())
      |> Map.put_new(:authorized_at, DateTime.add(now, -3600, :second))
      |> Map.put_new(:authorization_expires_at, DateTime.add(now, 3600, :second))
      |> Map.put_new(:actor_id, Ecto.UUID.generate())
      |> Map.put_new(:actor_name, "Some User")
      |> Map.put_new(:actor_email, "user@example.com")
      |> Map.put_new(:resource_id, Ecto.UUID.generate())
      |> Map.put_new(:resource_name, "GitLab")
      |> Map.put_new(:resource_address, "gitlab.company.com")
      |> Map.put_new(:inner_src_ip, %Postgrex.INET{address: {100, 64, 0, 1}})
      |> Map.put_new(:inner_dst_ip, %Postgrex.INET{address: {10, 0, 0, 5}})
      |> Map.put_new(:inner_src_port, 54_321)
      |> Map.put_new(:inner_dst_port, 443)
      |> Map.put_new(:outer_src_ip, %Postgrex.INET{address: {203, 0, 113, 10}})
      |> Map.put_new(:outer_dst_ip, %Postgrex.INET{address: {198, 51, 100, 5}})
      |> Map.put_new(:outer_src_port, 51_820)
      |> Map.put_new(:outer_dst_port, 51_820)
      |> Map.put_new(:rx_packets, 100)
      |> Map.put_new(:tx_packets, 80)
      |> Map.put_new(:rx_bytes, 102_400)
      |> Map.put_new(:tx_bytes, 20_480)
      |> Map.put_new(:inserted_at, now)

    {1, [flow_log]} = Repo.insert_all(FlowLog, [row], returning: true)

    flow_log
  end

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
        "uploads_enabled" => true,
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
