defmodule Web.Mailer.BetaEmail do
  use Web, :html
  import Swoosh.Email
  import Web.Mailer

  embed_templates "beta_email/*.text", suffix: "_text"

  def rest_api_beta_email(
        %Domain.Accounts.Account{} = account,
        %Domain.Auth.Subject{} = subject
      ) do
    default_email()
    |> subject("REST API Beta Request - #{account.slug}")
    |> to("support@firezone.dev")
    |> reply_to(
      Kernel.get_in(subject, :identity, :provider_identifier) || "notifications@firezone.dev"
    )
    |> render_text_body(__MODULE__, :rest_api_request,
      account: account,
      subject: subject
    )
  end
end
