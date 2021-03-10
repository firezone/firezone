defmodule FgHttpWeb.SessionView do
  use FgHttpWeb, :view
  alias FgHttp.Users

  # Don't allow user to enter email if signups are disabled.
  def email_field_opts do
    if signups_disabled?() do
      [class: "input", readonly: true, value: Users.admin_email()]
    else
      [class: "input"]
    end
  end

  defp signups_disabled? do
    Application.fetch_env!(:fg_http, :disable_signup)
  end
end
