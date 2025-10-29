defmodule API.Gateway.Views.Subject do
  alias Domain.Auth

  def render(%Auth.Subject{} = subject) do
    %{
      identity_name: get_in(subject, [Access.key(:actor), Access.key(:name)]),
      actor_email: get_in(subject, [Access.key(:identity), Access.key(:email)])
    }
  end
end
