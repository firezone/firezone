defmodule Portal.Mailer.Notifications do
  import Swoosh.Email
  import Portal.Mailer
  import Phoenix.Template, only: [embed_templates: 2]

  use Phoenix.VerifiedRoutes,
    endpoint: PortalWeb.Endpoint,
    router: PortalWeb.Router,
    statics: PortalWeb.static_paths()

  embed_templates "notifications/*.html", suffix: "_html"
  embed_templates "notifications/*.text", suffix: "_text"

  def outdated_gateway_email(account, gateways, incompatible_client_count, recipients) do
    params = %{clients_order_by: "latest_session:asc:version"}
    outdated_clients_url = url(~p"/#{account.id}/clients?#{params}")

    default_email()
    |> subject("Firezone Gateway Upgrade Available")
    |> put_recipients(recipients)
    |> with_account_id(account.id)
    |> render_body(__MODULE__, :outdated_gateway,
      account: account,
      gateways: gateways,
      outdated_clients_url: outdated_clients_url,
      incompatible_client_count: incompatible_client_count,
      latest_version: Portal.ComponentVersions.gateway_version()
    )
  end

  def limits_exceeded_email(account, warning, recipients) do
    billing_url = url(~p"/#{account.id}/settings/billing")
    plan_type = Portal.Billing.plan_type(account)

    default_email()
    |> subject("Firezone Account Limits Exceeded")
    |> put_recipients(recipients)
    |> with_account_id(account.id)
    |> render_body(__MODULE__, :limits_exceeded,
      account: account,
      warning: warning,
      billing_url: billing_url,
      plan_type: plan_type
    )
  end

  defp put_recipients(email, recipients) when is_list(recipients),
    do: bcc_recipients(email, recipients)

  defp put_recipients(email, recipient), do: to(email, recipient)
end
