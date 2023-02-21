defmodule FzHttp.OIDC.Refresher do
  @moduledoc """
  Worker module for refreshing OIDC connections
  """
  use GenServer, restart: :temporary
  import Ecto.{Changeset, Query}
  alias FzHttp.{Auth, OIDC, OIDC.Connection, Repo, Users}
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
    connections = Repo.all(from Connection, where: [user_id: ^user_id])
    Enum.each(connections, &do_refresh(user_id, &1))
    {:stop, :shutdown, user_id}
  end

  defp do_refresh(user_id, %{provider: provider_id, refresh_token: refresh_token} = conn) do
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

      user
      |> change()
      |> put_change(:disabled_at, DateTime.utc_now())
      |> prepare_changes(fn changeset ->
        FzHttp.Telemetry.disable_user()
        FzHttpWeb.Endpoint.broadcast("users_socket:#{user.id}", "disconnect", %{})
        changeset
      end)
      |> Repo.update!()
    end
  end

  defp enabled? do
    FzHttp.Config.fetch_config!(:disable_vpn_on_oidc_error)
  end
end
