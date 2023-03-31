defmodule FzHttp.Auth.OIDC.Refresher do
  @moduledoc """
  Worker module for refreshing OIDC connections
  """
  use GenServer, restart: :temporary
  alias FzHttp.{Auth, Auth.OIDC, Auth.OIDC.Connection, Repo, Users}
  require Logger

  def start_link(init_opts) do
    GenServer.start_link(__MODULE__, init_opts)
  end

  def init({user_id, delay}) do
    if enabled?() do
      {:ok, user_id, {:continue, {:delay, delay}}}
    else
      :ignore
    end
  end

  def handle_continue({:delay, delay}, user_id) do
    Process.sleep(delay)
    refresh(user_id)
  end

  def refresh(user_id) do
    Connection.Query.by_user_id(user_id)
    |> Repo.all()
    |> Enum.each(&do_refresh(&1, user_id))

    {:stop, :shutdown, user_id}
  end

  defp do_refresh(%{provider: provider_id, refresh_token: refresh_token} = conn, user_id) do
    Logger.info("Refreshing user\##{user_id} @ #{provider_id}...")

    refresh_response =
      with {:ok, config} <- Auth.fetch_oidc_provider_config(provider_id),
           {:ok, tokens} <-
             OpenIDConnect.fetch_tokens(config, %{
               grant_type: "refresh_token",
               refresh_token: refresh_token
             }) do
        tokens
      else
        {:error, reason} -> %{error: inspect(reason)}
      end

    OIDC.update_connection(conn, %{
      refreshed_at: DateTime.utc_now(),
      refresh_response: refresh_response
    })

    with %{error: _} <- refresh_response do
      user = Users.fetch_user_by_id!(user_id)
      Logger.info("Disabling user #{user.email} due to OIDC token refresh failure...")
      {:ok, user} = Users.disable_user(user)
      user
    end
  end

  defp enabled? do
    FzHttp.Config.fetch_config!(:disable_vpn_on_oidc_error)
  end
end
