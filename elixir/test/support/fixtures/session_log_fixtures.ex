defmodule Portal.SessionLogFixtures do
  @moduledoc """
  Test helpers for creating session_logs.
  """

  import Portal.AccountFixtures

  alias Portal.Repo
  alias Portal.SessionLog
  alias Portal.Types.EventId

  def session_log_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    account = Map.get(attrs, :account) || account_fixture()
    lsn = Map.get(attrs, :lsn, System.unique_integer([:positive, :monotonic]))

    row =
      attrs
      |> Map.drop([:account])
      |> Map.put_new(:event_id, EventId.build_session_log())
      |> Map.put_new(:account_id, account.id)
      |> Map.put_new(:lsn, lsn)
      |> Map.put_new(:timestamp, DateTime.utc_now())
      |> Map.put_new(:context, :client)
      |> Map.put_new(:device_id, Ecto.UUID.generate())
      |> Map.put_new(:token_id, Ecto.UUID.generate())
      |> Map.put_new(:user_agent, "testclient/1.0")
      |> Map.put_new(:remote_ip, %Postgrex.INET{address: {189, 172, 73, 1}})
      |> Map.put_new(:remote_ip_location_region, "US")
      |> Map.put_new(:remote_ip_location_city, "San Francisco")
      |> Map.put_new(:remote_ip_location_lat, 37.7749)
      |> Map.put_new(:remote_ip_location_lon, -122.4194)

    {1, [session_log]} = Repo.insert_all(SessionLog, [row], returning: true)

    session_log
  end
end
