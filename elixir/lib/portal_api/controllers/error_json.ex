defmodule PortalAPI.ErrorJSON do
  def render(_template, %{reason: reason} = _assigns) do
    %{error: %{reason: reason}}
  end

  def render(template, _assigns) do
    %{error: %{reason: Phoenix.Controller.status_message_from_template(template)}}
  end
end
