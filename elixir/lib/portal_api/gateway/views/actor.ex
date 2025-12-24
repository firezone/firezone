defmodule API.Gateway.Views.Actor do
  alias Domain.Actor

  def render(%Actor{} = actor) do
    %{
      id: actor.id
    }
  end
end
