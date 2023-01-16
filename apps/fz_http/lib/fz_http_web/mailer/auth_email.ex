defmodule FzHttpWeb.Mailer.AuthEmail do
  @moduledoc """
  This module generates emails that are Auth related.
  """
  use FzHttpWeb, :helper

  use Phoenix.Swoosh,
    template_root: Path.join(__DIR__, "templates"),
    template_path: "auth_email"

  alias FzHttpWeb.Mailer

  def magic_link(%FzHttp.Users.User{} = user) do
    Mailer.default_email()
    |> subject("Firezone Magic Link")
    |> to(user.email)
    |> render_body(:magic_link,
      link: url(~p"/auth/magic/#{user.id}/#{user.sign_in_token}")
    )
  end
end
