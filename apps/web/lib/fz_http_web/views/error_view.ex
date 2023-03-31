defmodule FzHttpWeb.ErrorView do
  use FzHttpWeb, :view

  # If you want to customize a particular status code
  # for a certain format, you may uncomment below.
  # def render("500.html", _assigns) do
  #   "Internal Server Error"
  # end

  def render("404.json", _assigns) do
    %{"error" => "not_found"}
  end

  # By default, Phoenix returns the status message from
  # the template name. For example, "404.html" becomes
  # "Not Found".
  def template_not_found(template, assigns) do
    default_reason = Phoenix.Controller.status_message_from_template(template)
    reason = assigns[:reason] || default_reason

    if String.ends_with?(template, ".json") do
      %{"error" => reason}
    else
      reason
    end
  end
end
