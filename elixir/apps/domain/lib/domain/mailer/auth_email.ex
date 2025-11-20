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
    |> to(identity.actor.email)
    |> render_body(__MODULE__, :sign_up_link,
      account: account,
      sign_in_form_url: sign_in_form_url,
      user_agent: user_agent,
      remote_ip: "#{:inet.ntoa(remote_ip)}"
    )
  end

  def sign_in_link_email(
        %Domain.Auth.Identity{} = identity,
        token_created_at,
        auth_provider_id,
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
        "/#{identity.account.slug}/sign_in/email_otp/#{auth_provider_id}/verify",
        params
      )

    token_created_at =
      Cldr.DateTime.to_string!(token_created_at, Domain.CLDR, format: :short) <> " UTC"

    default_email()
    |> subject("Firezone sign in token")
    |> to(identity.actor.email)
    |> render_body(__MODULE__, :sign_in_link,
      account: identity.account,
      client_platform: params["client_platform"],
      token_created_at: token_created_at,
      secret: secret,
      sign_in_url: sign_in_url,
      user_agent: user_agent,
      remote_ip: "#{:inet.ntoa(remote_ip)}"
    )
  end

  def new_user_email(
        %Domain.Accounts.Account{} = account,
        %Domain.Actors.Actor{} = actor,
        %Domain.Auth.Subject{} = subject
      ) do
    default_email()
    |> subject("Welcome to Firezone")
    |> to(actor.email)
    |> render_body(__MODULE__, :new_user,
      account: account,
      actor: actor,
      subject: subject
    )
  end
end
