defmodule FzHttpWeb.DeviceLive.CreateFormComponent do
  @moduledoc """
  Handles create device form.
  """
  use FzHttpWeb, :live_component

  alias FzHttp.{Devices, Users}

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(:changeset, Devices.new_device())
     |> assign(:options_for_select, Users.as_options_for_select())
     |> assign(assigns)}
  end
end
