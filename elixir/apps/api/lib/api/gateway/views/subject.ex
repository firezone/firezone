defmodule API.Gateway.Views.Subject do
  alias Domain.Auth

  def render(%Auth.Subject{} = subject) do
    %{
      identity_id: get_in(subject, [Access.key(:identity), Access.key(:id)]),
      identity_name: subject.actor.name,
      actor_id: subject.actor.id,
      actor_email: get_in(subject, [Access.key(:identity), Access.key(:email)])
    }
  end
end
