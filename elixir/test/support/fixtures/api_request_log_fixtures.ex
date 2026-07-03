defmodule Portal.APIRequestLogFixtures do
  @moduledoc """
  Test helpers for creating api_request_logs.
  """

  import Portal.AccountFixtures

  alias Portal.APIRequestLog
  alias Portal.Repo
  alias Portal.Types.EventId

  def api_request_log_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    account = Map.get(attrs, :account) || account_fixture()

    row =
      attrs
      |> Map.drop([:account])
      |> Map.put_new(:event_id, EventId.build_api_request_log())
      |> Map.put_new(:account_id, account.id)
      |> Map.put_new(:actor_id, Ecto.UUID.generate())
      |> Map.put_new(:api_token_id, Ecto.UUID.generate())
      |> Map.put_new(:method, "GET")
      |> Map.put_new(:path, "/account")
      |> Map.put_new(:request_id, "F8nMlbf6MUyJZUUABBzB9-yT")
      |> Map.put_new(:user_agent, "testclient/1.0")
      |> Map.put_new(:remote_ip, %Postgrex.INET{address: {189, 172, 73, 1}})
      |> Map.put_new(:inserted_at, DateTime.utc_now())

    {1, [api_request_log]} = Repo.insert_all(APIRequestLog, [row], returning: true)

    api_request_log
  end
end
