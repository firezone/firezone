defmodule Portal.Mailer.RevocationEmail do
  import Swoosh.Email
  import Portal.Mailer
  import Phoenix.Template, only: [embed_templates: 2]
  alias Portal.Crypto.X509

  use Phoenix.VerifiedRoutes,
    endpoint: PortalWeb.Endpoint,
    router: PortalWeb.Router,
    statics: PortalWeb.static_paths()

  embed_templates "revocation_email/*.html", suffix: "_html"
  embed_templates "revocation_email/*.text", suffix: "_text"

  def revocation_endpoint_error_email(endpoint, recipients) do
    issuer = X509.describe_name(endpoint.issuer)
    settings_url = url(~p"/#{endpoint.account}/settings/trust_anchors")

    default_email()
    |> subject("Certificate revocation checks have stopped - #{issuer}")
    |> put_recipients(recipients)
    |> with_account_id(endpoint.account.id)
    |> render_body(__MODULE__, :revocation_endpoint_error,
      account: endpoint.account,
      endpoint: endpoint,
      issuer: issuer,
      error_message: error_message(endpoint),
      settings_url: settings_url
    )
  end

  defp put_recipients(email, recipients) when is_list(recipients),
    do: bcc_recipients(email, recipients)

  defp put_recipients(email, recipient), do: to(email, recipient)

  defp error_message(endpoint) do
    endpoint.crl_error || endpoint.ocsp_error || "No error message available"
  end
end
