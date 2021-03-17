defmodule FgHttpWeb.DeviceDetailsLive do
  @moduledoc """
  Manages the Device details live view.
  """

  use Phoenix.LiveView

  def mount(_params, session, socket) do
    locals = %{
      device: session["device"]
    }

    {:ok, assign(socket, locals)}
  end
end
