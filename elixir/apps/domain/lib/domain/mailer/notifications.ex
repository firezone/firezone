defmodule Domain.Mailer.Notifications do
  import Swoosh.Email
  import Domain.Mailer
  import Phoenix.Template, only: [embed_templates: 2]

  embed_templates "notifications/*.html", suffix: "_html"
  embed_templates "notifications/*.text", suffix: "_text"

  def outdated_gateway_email(account, gateways, email) do
    default_email()
    |> subject("Firezone Gateway Upgrade Available")
    |> to(email)
    |> render_body(__MODULE__, :outdated_gateway,
      account: account,
      gateways: gateways,
      latest_version: Domain.ComponentVersions.gateway_version()
    )
  end
end
