defmodule Portal.Mailer.Notifications do
  import Swoosh.Email
  import Portal.Mailer
  import Phoenix.Template, only: [embed_templates: 2]

  embed_templates "notifications/*.html", suffix: "_html"
  embed_templates "notifications/*.text", suffix: "_text"

  def outdated_gateway_email(account, gateways, incompatible_client_count, email) do
    outdated_clients_url =
      url("/#{account.id}/clients", %{clients_order_by: "clients:asc:last_seen_version"})

    default_email()
    |> subject("Firezone Gateway Upgrade Available")
    |> to(email)
    |> render_body(__MODULE__, :outdated_gateway,
      account: account,
      gateways: gateways,
      outdated_clients_url: outdated_clients_url,
      incompatible_client_count: incompatible_client_count,
      latest_version: Portal.ComponentVersions.gateway_version()
    )
  end
end
