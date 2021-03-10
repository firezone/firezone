defmodule FgHttpWeb.SessionView do
  use FgHttpWeb, :view
  alias FgHttp.Users

  # Guess email if signups are disabled and only one user exists
  def email_field_opts(opts \\ []) when is_list(opts) do
    if Users.single_user?() and signups_disabled?() do
      opts ++ [value: Users.admin_email()]
    else
      opts
    end
  end

  defp signups_disabled? do
    Application.fetch_env!(:fg_http, :disable_signup)
  end
end
