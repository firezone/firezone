defmodule FzHttp.Mailer.AuthEmail do
  @moduledoc """
  This module generates emails that are Auth related.
  """

  use Phoenix.Swoosh,
    template_root: Path.join(__DIR__, "templates"),
    template_path: "auth_email"

  alias FzHttp.Mailer
  alias FzHttpWeb.Router.Helpers, as: Routes

  def magic_link(%FzHttp.Users.User{} = user) do
    Mailer.default_email()
    |> subject("Firezone Magic Link")
    |> to(user.email)
    |> render_body(:magic_link,
      link: Routes.auth_url(FzHttpWeb.Endpoint, :magic_sign_in, user.sign_in_token)
    )
  end
end
