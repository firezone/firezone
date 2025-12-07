defmodule Domain.Mailer.SyncEmail do
  import Swoosh.Email
  import Domain.Mailer
  import Phoenix.Template, only: [embed_templates: 2]

  embed_templates "sync_email/*.html", suffix: "_html"
  embed_templates "sync_email/*.text", suffix: "_text"

  def sync_error_email(directory, email) do
    default_email()
    |> subject("Directory Sync Error - #{directory.name}")
    |> to(email)
    |> render_body(__MODULE__, :sync_error, account: directory.account, directory: directory)
  end
end
