defmodule API.Gateway.Views.Subject do
  alias Domain.Auth

  def render(%Auth.Subject{} = subject) do
    %{
      # TODO: Fix access to these fields.
      identity_name: subject.actor.name,
      actor_email: subject.identity.email
    }
  end
end
