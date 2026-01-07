defmodule Portal.Mailer.AccountDelete do
  import Swoosh.Email
  import Portal.Mailer
  import Phoenix.Template, only: [embed_templates: 2]

  embed_templates "account_delete_email/*.text", suffix: "_text"

  def account_delete_email(
        %Portal.Account{} = account,
        %Portal.Auth.Subject{} = subject
      ) do
    default_email()
    |> subject("ACCOUNT DELETE REQUEST - #{account.id}")
    |> to("support@firezone.dev")
    |> render_text_body(__MODULE__, :account_delete_request, account: account, subject: subject)
  end
end
