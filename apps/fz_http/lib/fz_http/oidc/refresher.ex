defmodule FzHttp.OIDC.Refresher do
  @moduledoc """
  Worker module for refreshing OIDC connections
  """
  use GenServer, restart: :temporary

  import Ecto.{Changeset, Query}
  alias FzHttp.{OIDC, OIDC.Connection, Repo, Users}
  require Logger

  def start_link(init_opts) do
    GenServer.start_link(__MODULE__, init_opts)
  end

  def init({user_id, delay}) do
    {:ok, user_id, {:continue, {:delay, delay}}}
  end

  def handle_continue({:delay, delay}, user_id) do
    Process.sleep(delay)
    refresh(user_id)
  end

  def refresh(user_id) do
    connections = Repo.all(from Connection, where: [user_id: ^user_id])
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
        {:ok, refreshed} ->
          refreshed

        {:error, :fetch_tokens, %{body: body}} ->
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
      |> change()
      |> put_change(:allowed_to_connect, false)
      |> Repo.update!()
    end
  end

  defp openid_connect do
    Application.fetch_env!(:fz_http, :openid_connect)
  end
end
