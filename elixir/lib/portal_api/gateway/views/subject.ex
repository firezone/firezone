defmodule API.Gateway.Views.Subject do
  alias Domain.Auth

  def render(%Auth.Subject{} = subject) do
    %{
      auth_provider_id: subject.credential.auth_provider_id,
      actor_id: subject.actor.id,
      actor_email: subject.actor.email,
      actor_name: subject.actor.name
    }
  end
end
