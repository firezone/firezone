defmodule FzHttpWeb.SessionView do
  use FzHttpWeb, :view

  alias FzHttp.Users

  # Guess email if signups are disabled and only one user exists
  def email_field_opts(opts \\ []) do
    if Users.single_user?() do
      opts ++ [value: Users.admin_email()]
    else
      opts
    end
  end
end
