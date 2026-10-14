defmodule Portal.Mailer.AccountInactivity do
  import Swoosh.Email
  import Portal.Mailer
  import Phoenix.Template, only: [embed_templates: 2]

  use Phoenix.VerifiedRoutes,
    endpoint: PortalWeb.Endpoint,
    router: PortalWeb.Router,
    statics: PortalWeb.static_paths()

  embed_templates("account_inactivity/*.html", suffix: "_html")
  embed_templates("account_inactivity/*.text", suffix: "_text")

  def reminder_email(account, recipients, reason) do
    message =
      if reason == "default" do
        "Your account appears to have no activity or setup beyond its initial signup."
      else
        "Your account has had no recorded session activity for at least 12 months."
      end

    email(
      account,
      recipients,
      "Keep your Firezone account",
      message,
      "Sign in within two weeks to keep your account. Otherwise, we will schedule it for deletion.",
      url(~p"/#{account.slug}/sign_in")
    )
  end

  def scheduled_email(account, recipients) do
    date = Calendar.strftime(account.scheduled_deletion_at, "%B %-d, %Y")

    email(
      account,
      recipients,
      "Firezone account scheduled for deletion due to inactivity",
      "We did not record activity during the two-week reminder period.",
      "Your account is now scheduled for permanent deletion on #{date}. Contact support@firezone.dev before that date if you need to keep it.",
      url(~p"/#{account.slug}/settings/account")
    )
  end

  defp email(account, recipients, heading, message, action, link) do
    default_email()
    |> subject(heading)
    |> reply_to("support@firezone.dev")
    |> bcc_recipients(recipients)
    |> with_account_id(account.id)
    |> render_body(__MODULE__, :notice,
      account: account,
      heading: heading,
      message: message,
      action: action,
      link: link
    )
  end
end
