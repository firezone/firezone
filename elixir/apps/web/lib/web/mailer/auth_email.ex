defmodule Web.Mailer.AuthEmail do
  use Web, :html
  import Swoosh.Email
  import Web.Mailer

  embed_templates "auth_email/*.html", suffix: "_html"
  embed_templates "auth_email/*.text", suffix: "_text"

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

    sign_in_link =
      url(
        ~p"/#{identity.account}/providers/#{identity.provider_id}/verify_sign_in_token?#{params}"
      )

    default_email()
    |> subject("Firezone Sign In Link")
    |> to(identity.provider_identifier)
    |> render_body(__MODULE__, :sign_in_link,
      account: identity.account,
      client_platform: params["client_platform"],
      sign_in_token_created_at:
        Cldr.DateTime.to_string!(identity.provider_state["sign_in_token_created_at"], Web.CLDR,
          format: :short
        ) <> " UTC",
      secret: email_secret,
      link: sign_in_link,
      user_agent: user_agent,
      remote_ip: "#{:inet.ntoa(remote_ip)}"
    )
  end
end
