defmodule Portal.Mailer.SupportEmail do
  import Swoosh.Email
  import Portal.Mailer
  import Phoenix.Template, only: [embed_templates: 2]

  embed_templates "support_email/*.text", suffix: "_text"

  def registration_link_email(email, registration_url) when is_binary(email) do
    default_email()
    |> subject("Register your Firezone Support passkey")
    |> to(email)
    |> render_text_body(__MODULE__, :registration_link,
      recipient_email: email,
      registration_url: registration_url
    )
  end

  def sign_in_otp_email(email, code, %Portal.Account{} = account) when is_binary(email) do
    default_email()
    |> subject("Firezone Support sign-in code")
    |> to(email)
    |> with_account_id(account.id)
    |> render_text_body(__MODULE__, :sign_in_otp, code: code, account: account)
  end

  def support_request_email(
        %Portal.Account{} = account,
        %Portal.Actor{} = actor,
        problem,
        access_granted?
      ) do
    default_email()
    |> subject("SUPPORT REQUEST - #{account.name} (#{account.id})")
    |> to("support@firezone.dev")
    |> with_account_id(account.id)
    |> render_text_body(__MODULE__, :support_request,
      account: account,
      actor: actor,
      problem: problem,
      access_granted?: access_granted?
    )
  end
end
