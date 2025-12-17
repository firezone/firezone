defmodule Portal.Mailer.SyncEmail do
  import Swoosh.Email
  import Portal.Mailer
  import Phoenix.Template, only: [embed_templates: 2]

  use Phoenix.VerifiedRoutes,
    endpoint: PortalWeb.Endpoint,
    router: PortalWeb.Router,
    statics: PortalWeb.static_paths()

  embed_templates "sync_email/*.html", suffix: "_html"
  embed_templates "sync_email/*.text", suffix: "_text"

  def sync_error_email(directory, email) do
    settings_url = url(~p"/#{directory.account.slug}/settings/directory_sync")

    default_email()
    |> subject("Directory Sync Error - #{directory.name}")
    |> to(email)
    |> render_body(__MODULE__, :sync_error,
      account: directory.account,
      directory: directory,
      settings_url: settings_url
    )
  end
end
