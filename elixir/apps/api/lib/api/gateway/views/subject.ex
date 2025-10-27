defmodule API.Gateway.Views.Subject do
  alias Domain.Auth

  def render(%Auth.Subject{} = subject) do
    %{
      name: subject.actor.name,
      email: subject.identity.email
    }
  end
end
