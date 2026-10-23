defmodule Portal.Ops.AuthProviderNotices do
  @moduledoc false

  import Phoenix.Template, only: [embed_templates: 2]
  import Swoosh.Email
  alias Portal.Mailer

  use Phoenix.VerifiedRoutes,
    endpoint: PortalWeb.Endpoint,
    router: PortalWeb.Router,
    statics: PortalWeb.static_paths()

  embed_templates "auth_provider_notices/*.html", suffix: "_html"
  embed_templates "auth_provider_notices/*.text", suffix: "_text"

  def email(provider, notice) when provider in [:entra, :google] do
    subject = notice_subject(provider, notice.name)

    email =
      Mailer.default_email()
      |> subject(subject)
      |> Mailer.with_account_id(notice.account_id)
      |> Mailer.render_body(__MODULE__, provider,
        notice: notice,
        settings_url: url(~p"/#{notice.slug}/settings/authentication")
      )

    Mailer.render_body(email, __MODULE__, :notice,
      subject: subject,
      announcement_html: rendered_html(email.html_body),
      announcement_text: email.text_body
    )
  end

  defp notice_subject(:entra, name), do: "Action required: Microsoft Entra sign-in for #{name}"
  defp notice_subject(:google, name), do: "Google sign-in update for #{name}"

  # The body is rendered by the escaped HTML templates in this module.
  # sobelow_skip ["XSS.Raw"]
  defp rendered_html(html), do: Phoenix.HTML.raw(html)
end
