defmodule Portal.Mailer.BetaEmail do
  import Swoosh.Email
  import Portal.Mailer
  import Phoenix.Template, only: [embed_templates: 2]

  embed_templates "beta_email/*.text", suffix: "_text"

  def rest_api_beta_email(
        %Portal.Account{} = account,
        %Portal.Authentication.Subject{} = subject
      ) do
    default_email()
    |> subject("REST API Beta Request - #{account.id}")
    |> to("support@firezone.dev")
    |> render_text_body(__MODULE__, :rest_api_request, account: account, subject: subject)
  end
end
