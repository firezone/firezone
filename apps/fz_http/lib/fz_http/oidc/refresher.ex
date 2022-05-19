defmodule FzHttp.OIDC.Refresher do
  @moduledoc """
  Worker module for refreshing OIDC connections
  """
  use GenServer, restart: :temporary

  import Ecto.Query
  alias FzHttp.{Repo, OIDC.Connection, OIDC, Users.User, Users}
  require Logger

  @delay_range 15

  def start_link(user_id) do
    GenServer.start_link(__MODULE__, user_id)
  end

  def init(user_id) do
    {:ok, user_id, {:continue, :delay}}
  end

  def handle_continue(:delay, user_id) do
    Process.sleep(Enum.random(1..@delay_range) * 1000)
    refresh(user_id)
  end

  defp refresh(user_id) do
    connections = Repo.all(from(Connection, where: [user_id: ^user_id]))
    Enum.each(connections, &do_refresh(user_id, &1))
    {:stop, :shutdown, user_id}
  end

  defp do_refresh(user_id, %{provider: provider, refresh_token: refresh_token} = conn) do
    provider = String.to_existing_atom(provider)

    Logger.info("Refreshing user\##{user_id} @ #{provider}...")

    result =
      openid_connect().fetch_tokens(
        provider,
        %{grant_type: "refresh_token", refresh_token: refresh_token}
      )

    refresh_response =
      case result do
        {:ok, refreshed_claims} ->
          refreshed_claims

        {:error, _, %{body: body}} ->
          %{error: body}

        _ ->
          %{error: "unknown error"}
      end

    OIDC.update_connection(conn, %{
      refreshed_at: DateTime.utc_now(),
      refresh_response: refresh_response
    })

    with %{error: _} <- refresh_response do
      Logger.info("Disabling user\##{user_id}...")

      user_id
      |> Users.get_user!()
      |> User.changeset(%{last_signed_in_at: ~U[1970-01-01 00:00:00Z]})
      |> Repo.update!()
    end
  end

  defp openid_connect do
    Application.fetch_env!(:fz_http, :openid_connect)
  end
end
