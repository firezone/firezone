defmodule Portal.ClientSessionFixtures do
  @moduledoc """
  Test helpers for creating client sessions.
  """

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.ClientFixtures
  import Portal.TokenFixtures

  def client_session_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    account = Map.get(attrs, :account) || account_fixture()
    actor = Map.get(attrs, :actor) || actor_fixture(account: account)
    client = Map.get(attrs, :client) || client_fixture(account: account, actor: actor)
    token = Map.get(attrs, :token) || client_token_fixture(account: account, actor: actor)

    session_attrs =
      attrs
      |> Map.drop([:account, :actor, :client, :token])
      |> Map.put_new(:user_agent, "macOS/14.0 apple-client/1.3.0")
      |> Map.put_new(:remote_ip, {100, 64, 0, 1})
      |> Map.put_new(:remote_ip_location_region, "US")
      |> Map.put_new(:version, "1.3.0")

    {:ok, session} =
      %Portal.ClientSession{}
      |> Ecto.Changeset.cast(session_attrs, [
        :user_agent,
        :remote_ip,
        :remote_ip_location_region,
        :remote_ip_location_city,
        :remote_ip_location_lat,
        :remote_ip_location_lon,
        :version
      ])
      |> Ecto.Changeset.put_change(:account_id, account.id)
      |> Ecto.Changeset.put_change(:client_id, client.id)
      |> Ecto.Changeset.put_change(:client_token_id, token.id)
      |> Portal.ClientSession.changeset()
      |> Portal.Repo.insert()

    session
  end
end
