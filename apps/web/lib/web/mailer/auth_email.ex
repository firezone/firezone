defmodule Web.Mailer.AuthEmail do
  use Web, :verified_routes

  use Phoenix.Swoosh,
    template_root: Path.join(__DIR__, "templates"),
    template_path: "auth_email"

  alias Web.Mailer
end
