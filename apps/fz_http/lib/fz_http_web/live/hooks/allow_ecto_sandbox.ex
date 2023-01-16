defmodule FzHttpWeb.Hooks.AllowEctoSandbox do
  def on_mount(:default, _params, _session, socket) do
    socket = FzHttpWeb.Sandbox.allow_live_ecto_sandbox(socket)
    {:cont, socket}
  end
end
