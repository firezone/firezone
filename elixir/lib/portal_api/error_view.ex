defmodule PortalAPI.ErrorView do
  @moduledoc """
  Renders the errors Phoenix raises outside a controller, such as an unknown
  route, in the same RFC 9457 shape the controllers use.
  """

  def render(template, _assigns) do
    status = template |> String.split(".") |> hd() |> String.to_integer()

    %{
      type: "about:blank",
      title: Plug.Conn.Status.reason_phrase(status),
      status: status
    }
  end
end
