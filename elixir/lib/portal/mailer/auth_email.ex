defmodule Portal.Mailer.AuthEmail do
  import Swoosh.Email
  import Portal.Mailer
  import Phoenix.Template, only: [embed_templates: 2]

  use Phoenix.VerifiedRoutes,
    endpoint: PortalWeb.Endpoint,
    router: PortalWeb.Router,
    statics: PortalWeb.static_paths()

  embed_templates "auth_email/*.html", suffix: "_html"
  embed_templates "auth_email/*.text", suffix: "_text"

  def sign_up_link_email(
        %Portal.Account{} = account,
        %Portal.Actor{} = actor,
        user_agent,
        remote_ip
      ) do
    sign_in_form_url = url(~p"/#{account.slug}")

    default_email()
    |> subject("Welcome to Firezone")
    |> to(actor.email)
    |> render_body(__MODULE__, :sign_up_link,
      account: account,
      sign_in_form_url: sign_in_form_url,
      user_agent: user_agent,
      remote_ip: "#{:inet.ntoa(remote_ip)}"
    )
  end

  def sign_in_link_email(
        %Portal.Actor{} = actor,
        token_created_at,
        auth_provider_id,
        secret,
        user_agent,
        remote_ip,
        params \\ %{}
      ) do
    params = Map.merge(params, %{secret: secret})
    query = Plug.Conn.Query.encode(params)

    sign_in_url =
      url(~p"/#{actor.account.slug}/sign_in/email_otp/#{auth_provider_id}/verify?#{query}")

    token_created_at =
      Cldr.DateTime.to_string!(token_created_at, Portal.CLDR, format: :short) <> " UTC"

    default_email()
    |> subject("Firezone sign in token")
    |> to(actor.email)
    |> render_body(__MODULE__, :sign_in_link,
      account: actor.account,
      client_sign_in: params["as"] == "client",
      sign_in_token_created_at: token_created_at,
      secret: secret,
      sign_in_url: sign_in_url,
      user_agent: user_agent,
      remote_ip: "#{:inet.ntoa(remote_ip)}"
    )
  end

  def new_user_email(
        %Portal.Account{} = account,
        %Portal.Actor{} = actor,
        %Portal.Auth.Subject{} = subject
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
