defmodule FzHttp.Mailer.UserEmail do
  use Phoenix.Swoosh,
    template_root: Path.join(__DIR__, "templates"),
    template_path: "user_email"

  alias FzHttp.Mailer

  def reset_password(%FzHttp.Users.User{} = user) do
    Mailer.default_email()
    |> subject("Firezone Password Reset")
    |> to(user.email)
    |> render_body("reset_password.html", link: "https://test.test")
  end
end
