defmodule Portal.FlowLogFixtures do
  @moduledoc """
  Test helpers for creating flow_logs.
  """

  import Portal.AccountFixtures

  alias Portal.FlowLog
  alias Portal.Repo
  alias Portal.Types.EventId

  def flow_log_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    account = Map.get(attrs, :account) || account_fixture()
    now = DateTime.utc_now()

    row =
      attrs
      |> Map.drop([:account])
      |> Map.put_new(:account_id, account.id)
      |> Map.put_new(:event_id, EventId.build_flow_log())
      |> Map.put_new(:device_id, Ecto.UUID.generate())
      |> Map.put_new(:role, "responder")
      |> Map.put_new(:protocol, "tcp")
      |> Map.put_new(:flow_start, DateTime.add(now, -60, :second))
      |> Map.put_new(:flow_end, DateTime.add(now, -30, :second))
      |> Map.put_new(:last_packet, DateTime.add(now, -30, :second))
      |> Map.put_new(:actor_id, Ecto.UUID.generate())
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
end
