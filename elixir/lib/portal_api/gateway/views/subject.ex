defmodule PortalAPI.Gateway.Views.Subject do
  alias Portal.Authentication

  def render(%Authentication.Subject{} = subject) do
    Authentication.Subject.to_map(subject)
  end
end
