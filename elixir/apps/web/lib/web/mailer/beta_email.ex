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
    |> render_text_body(__MODULE__, :rest_api_request,
      account: account,
      subject: subject
    )
  end

  # def sign_up_link_email(
  #      %Domain.Accounts.Account{} = account,
  #      %Domain.Auth.Identity{} = identity,
  #      user_agent,
  #      remote_ip
  #    ) do
  #  sign_in_form_url = url(~p"/#{account}")

  #  default_email()
  #  |> subject("Welcome to Firezone")
  #  |> to(identity.provider_identifier)
  #  |> render_body(__MODULE__, :sign_up_link,
  #    account: account,
  #    sign_in_form_url: sign_in_form_url,
  #    user_agent: user_agent,
  #    remote_ip: "#{:inet.ntoa(remote_ip)}"
  #  )
  # end
end
