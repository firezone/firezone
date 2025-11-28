defmodule Domain.Mailer.AccountDelete do
  import Swoosh.Email
  import Domain.Mailer
  import Phoenix.Template, only: [embed_templates: 2]

  embed_templates "account_delete_email/*.text", suffix: "_text"

  def account_delete_email(
        %Domain.Accounts.Account{} = account,
        %Domain.Auth.Subject{} = subject
      ) do
    default_email()
    |> subject("ACCOUNT DELETE REQUEST - #{account.slug}")
    |> to("support@firezone.dev")
    |> render_text_body(__MODULE__, :account_delete_request, account: account)
  end
end
