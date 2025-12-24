defmodule PortalAPI.Gateway.Views.Actor do
  alias Portal.Actor

  def render(%Actor{} = actor) do
    %{
      id: actor.id
    }
  end
end
