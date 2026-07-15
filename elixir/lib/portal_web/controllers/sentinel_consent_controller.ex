defmodule PortalWeb.SentinelConsentController do
  @moduledoc """
  Landing for the Microsoft Sentinel admin consent redirect. Entra requires a
  registered reply address even though nothing stateful happens here; the
  outcome is surfaced as a flash and the admin returns to the log sink
  settings page named by `state`.
  """
  use PortalWeb, :controller

  def callback(conn, %{"admin_consent" => "True"} = params) do
    conn
    |> put_flash(
      :info,
      "Admin consent granted. Finish configuring your Microsoft Sentinel log sink below."
    )
    |> redirect(to: return_path(params))
  end

  def callback(conn, %{"error" => error} = params) do
    conn
    |> put_flash(:error, "Admin consent was not granted: #{params["error_description"] || error}")
    |> redirect(to: return_path(params))
  end

  def callback(conn, params) do
    redirect(conn, to: return_path(params))
  end

  defp return_path(%{"state" => account}) when is_binary(account) and account != "" do
    ~p"/#{account}/settings/log_sinks"
  end

  defp return_path(_params), do: ~p"/"
end
