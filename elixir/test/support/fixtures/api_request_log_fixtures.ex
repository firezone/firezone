defmodule Portal.APIRequestLogFixtures do
  @moduledoc """
  Test helpers for creating api_request_logs.
  """

  import Ecto.Changeset
  import Portal.AccountFixtures

  alias Portal.APIRequestLog
  alias Portal.Types.LogId

  def valid_api_request_log_attrs do
    %{
      log_id: LogId.build_api_request_log(),
      actor_id: Ecto.UUID.generate(),
      api_token_id: Ecto.UUID.generate(),
      method: "GET",
      path: "/account",
      request_id: "F8nMlbf6MUyJZUUABBzB9-yT",
      user_agent: "testclient/1.0",
      ip: %Postgrex.INET{address: {189, 172, 73, 1}}
    }
  end

  def api_request_log_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, valid_api_request_log_attrs())
    account = Map.get_lazy(attrs, :account, fn -> account_fixture() end)

    %APIRequestLog{}
    |> change(Map.drop(attrs, [:account]))
    |> put_assoc(:account, account)
    |> Portal.Repo.insert!()
  end
end
