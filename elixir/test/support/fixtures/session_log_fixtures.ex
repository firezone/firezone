defmodule Portal.SessionLogFixtures do
  @moduledoc """
  Test helpers for creating session_logs.
  """

  import Portal.AccountFixtures

  alias Portal.Repo
  alias Portal.SessionLog
  alias Portal.Types.EventId

  @subject_keys [:actor_id, :actor_email, :device_id, :token_id]

  def session_log_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    account = Map.get(attrs, :account) || account_fixture()

    # Convenience keys like `actor_id:` / `actor_email:` are folded into the
    # `subject` JSONB so callers can pin one field without building the map.
    {subject_overrides, attrs} = Map.split(attrs, @subject_keys)

    subject =
      subject_overrides
      |> Enum.map(fn {key, value} -> {to_string(key), value} end)
      |> Enum.into(Map.get(attrs, :subject, default_subject()))

    row =
      attrs
      |> Map.drop([:account, :subject])
      |> Map.put_new(:event_id, EventId.build_session_log())
      |> Map.put_new(:account_id, account.id)
      |> Map.put_new(:timestamp, DateTime.utc_now())
      |> Map.put_new(:context, :client)
      |> Map.put(:subject, subject)

    {1, [session_log]} = Repo.insert_all(SessionLog, [row], returning: true)

    session_log
  end

  defp default_subject do
    %{
      "actor_id" => Ecto.UUID.generate(),
      "actor_email" => "user@example.com",
      "device_id" => Ecto.UUID.generate(),
      "token_id" => Ecto.UUID.generate(),
      "ip" => "189.172.73.1",
      "ip_region" => "US",
      "ip_city" => "San Francisco",
      "ip_lat" => 37.7749,
      "ip_lon" => -122.4194,
      "user_agent" => "testclient/1.0"
    }
  end
end
