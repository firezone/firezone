defmodule API.Gateway.Views.Subject do
  alias Domain.Auth

  def render(%Auth.Subject{} = subject) do
    %{
      # TODO: This seems weird but I can't find the fields anywhere else.
      identity_name: subject.actor.name,
      actor_email: subject.identity.email
    }
  end
end
