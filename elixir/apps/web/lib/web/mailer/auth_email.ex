defmodule Web.Mailer.AuthEmail do
  use Web, :html
  import Swoosh.Email
  import Web.Mailer

  embed_templates "auth_email/*.html", suffix: "_html"
  embed_templates "auth_email/*.text", suffix: "_text"

  def sign_up_link_email(
        %Domain.Accounts.Account{} = account,
        %Domain.Auth.Identity{} = identity,
        user_agent,
        remote_ip
      ) do
    sign_in_form_url = url(~p"/#{account}")

    default_email()
    |> subject("Welcome to Firezone")
    |> to(identity.provider_identifier)
    |> render_body(__MODULE__, :sign_up_link,
      account: account,
      sign_in_form_url: sign_in_form_url,
      user_agent: user_agent,
      remote_ip: "#{:inet.ntoa(remote_ip)}"
    )
  end

  def sign_in_link_email(
        %Domain.Auth.Identity{} = identity,
        email_secret,
        user_agent,
        remote_ip,
        params \\ %{}
      ) do
    params =
      Map.merge(params, %{
        identity_id: identity.id,
        secret: email_secret
      })

    sign_in_url =
      url(
        ~p"/#{identity.account}/sign_in/providers/#{identity.provider_id}/verify_sign_in_token?#{params}"
      )

    default_email()
    |> subject("Firezone sign in token")
    |> to(identity.provider_identifier)
    |> render_body(__MODULE__, :sign_in_link,
      account: identity.account,
      client_platform: params["client_platform"],
      sign_in_token_created_at:
        Cldr.DateTime.to_string!(identity.provider_state["sign_in_token_created_at"], Web.CLDR,
          format: :short
        ) <> " UTC",
      secret: email_secret,
      sign_in_url: sign_in_url,
      user_agent: user_agent,
      remote_ip: "#{:inet.ntoa(remote_ip)}"
    )
  end
end
