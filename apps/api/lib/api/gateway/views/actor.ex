defmodule API.Gateway.Views.Actor do
  alias Domain.Actors

  def render(%Actors.Actor{} = actor) do
    %{
      id: actor.id
    }
  end
end
