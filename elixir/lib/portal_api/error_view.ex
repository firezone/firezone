defmodule PortalAPI.ErrorView do
  def render("500.json", _assigns) do
    %{error: %{reason: "internal_error"}}
  end

  # By default, Phoenix returns the status message from
  # the template name. For example, "404.json" becomes
  # "Not Found".
  def render(template, _assigns) do
    %{error: %{reason: Phoenix.Controller.status_message_from_template(template)}}
  end
end
