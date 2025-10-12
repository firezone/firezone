defmodule Domain.Mailer.AuthEmail do
  import Swoosh.Email
  import Domain.Mailer
  import Phoenix.Template, only: [embed_templates: 2]

  embed_templates "auth_email/*.html", suffix: "_html"
  embed_templates "auth_email/*.text", suffix: "_text"

  def sign_up_link_email(
        %Domain.Accounts.Account{} = account,
        %Domain.Auth.Identity{} = identity,
        user_agent,
        remote_ip
      ) do
    sign_in_form_url = url("/#{account.slug}")

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
        secret,
        user_agent,
        remote_ip,
        params \\ %{}
      ) do
    params =
      Map.merge(params, %{
        identity_id: identity.id,
        secret: secret
      })

    sign_in_url =
      url(
        "/#{identity.account.slug}/sign_in/providers/#{identity.provider_id}/verify_sign_in_token",
        params
      )

    sign_in_token_created_at =
      Cldr.DateTime.to_string!(identity.provider_state["token_created_at"], Domain.CLDR,
        format: :short
      ) <> " UTC"

    default_email()
    |> subject("Firezone sign in token")
    |> to(identity.provider_identifier)
    |> render_body(__MODULE__, :sign_in_link,
      account: identity.account,
      client_platform: params["client_platform"],
      sign_in_token_created_at: sign_in_token_created_at,
      secret: secret,
      sign_in_url: sign_in_url,
      user_agent: user_agent,
      remote_ip: "#{:inet.ntoa(remote_ip)}"
    )
  end

  def new_user_email(
        %Domain.Accounts.Account{} = account,
        %Domain.Auth.Identity{} = identity,
        %Domain.Auth.Subject{} = subject
      ) do
    default_email()
    |> subject("Welcome to Firezone")
    |> to(Domain.Auth.get_identity_email(identity))
    |> render_body(__MODULE__, :new_user,
      account: account,
      identity: identity,
      subject: subject
    )
  end
end
