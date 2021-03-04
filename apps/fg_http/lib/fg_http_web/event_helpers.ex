defmodule FgHttpWeb.EventHelpers do
  @moduledoc """
  Provides helpers for external events.
  """

  def vpn_pid do
    case :global.whereis_name(:fg_vpn_server) do
      :undefined ->
        {:error, "VPN server process not registered in global registry."}

      vpn_pid ->
        {:ok, vpn_pid}
    end
  end
end
