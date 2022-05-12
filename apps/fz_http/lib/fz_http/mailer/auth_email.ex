defmodule FzHttp.Mailer.AuthEmail do
  use Phoenix.Swoosh,
    template_root: Path.join(__DIR__, "templates"),
    template_path: "auth_email"

  alias FzHttp.Mailer

  def magic_link(%FzHttp.Users.User{} = user) do
    Mailer.default_email()
    |> subject("Firezone Magic Link")
    |> to(user.email)
    |> render_body("magic_link.html", link: "https://test.test")
  end
end
