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
    sign_in_form_url = url(~p"/#{account}")

    default_email()
    |> subject("Welcome to Firezone")
    |> to(actor.email)
    |> with_account_id(account.id)
    |> render_body(__MODULE__, :sign_up_link,
      account: account,
      sign_in_form_url: sign_in_form_url,
      user_agent: user_agent,
      remote_ip: obfuscated_remote_ip(remote_ip)
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

    sign_in_url =
      url(~p"/#{actor.account}/sign_in/email_otp/#{auth_provider_id}/verify?#{params}")

    token_created_at =
      PortalWeb.Format.short_datetime(token_created_at) <> " UTC"

    default_email()
    |> subject("Firezone sign in token")
    |> to(actor.email)
    |> with_account_id(actor.account.id)
    |> render_body(__MODULE__, :otp_email,
      account: actor.account,
      email_title: "Firezone Sign In Token",
      heading: "Finish Signing In!",
      code_instruction: "Copy and paste the following token into the Sign In form",
      link_instruction:
        "or click on the following link if you are on the same device where you are trying to sign in:",
      html_link_instruction: "Or click the button below",
      button_label: "Complete Sign In",
      unsolicited_action: "sign in",
      show_link?: not PortalWeb.Authentication.client_sign_in?(params),
      sign_in_token_created_at: token_created_at,
      secret: secret,
      sign_in_url: sign_in_url,
      user_agent: user_agent,
      remote_ip: obfuscated_remote_ip(remote_ip),
      request_location: nil
    )
  end

  def oidc_identity_verification_email(
        %Portal.Actor{} = actor,
        token_created_at,
        auth_provider_id,
        pending_identity_id,
        secret,
        %Portal.Authentication.Context{} = context,
        params \\ %{}
      ) do
    params = Map.merge(params, %{"pending_identity_id" => pending_identity_id})

    verify_url =
      url(~p"/#{actor.account}/sign_in/oidc/#{auth_provider_id}/verify_identity?#{params}")

    token_created_at =
      PortalWeb.Format.short_datetime(token_created_at) <> " UTC"

    default_email()
    |> subject("Firezone email verification code")
    |> to(actor.email)
    |> with_account_id(actor.account.id)
    |> render_body(__MODULE__, :otp_email,
      account: actor.account,
      email_title: "Firezone Email Verification Code",
      heading: "Verify Your Email Address",
      code_instruction: "Copy and paste the following code into the email verification form",
      link_instruction: "Use the following link to return to the email verification form:",
      html_link_instruction: "Click the button below to return to the verification form",
      button_label: "Enter Verification Code",
      unsolicited_action: "email verification",
      show_link?: true,
      sign_in_token_created_at: token_created_at,
      secret: secret,
      sign_in_url: verify_url,
      user_agent: context.user_agent,
      remote_ip: obfuscated_remote_ip(context.remote_ip),
      request_location: request_location(context)
    )
  end

  def sign_up_verification_email(email, sign_up_url) when is_binary(email) do
    default_email()
    |> subject("Complete your Firezone sign up")
    |> to(email)
    |> render_body(__MODULE__, :sign_up_verification, sign_up_url: sign_up_url)
  end

  def existing_accounts_email(email, accounts_with_urls) when is_binary(email) do
    default_email()
    |> subject("Your Firezone accounts")
    |> to(email)
    |> render_body(__MODULE__, :existing_accounts, accounts_with_urls: accounts_with_urls)
  end

  def no_accounts_found_email(email, sign_up_url) when is_binary(email) do
    default_email()
    |> subject("We couldn't find your Firezone account")
    |> to(email)
    |> render_body(__MODULE__, :no_accounts_found,
      recipient_email: email,
      sign_up_url: sign_up_url
    )
  end

  def sign_up_account_exists_email(email, accounts_with_urls) when is_binary(email) do
    default_email()
    |> subject("Your Firezone account")
    |> to(email)
    |> render_body(__MODULE__, :sign_up_account_exists, accounts_with_urls: accounts_with_urls)
  end

  def new_user_email(
        %Portal.Account{} = account,
        %Portal.Actor{} = actor,
        %Portal.Authentication.Subject{} = subject
      ) do
    default_email()
    |> subject("Welcome to Firezone")
    |> to(actor.email)
    |> with_account_id(account.id)
    |> render_body(__MODULE__, :new_user,
      account: account,
      actor: actor,
      subject: subject
    )
  end

  defp request_location(%Portal.Authentication.Context{} = context) do
    [context.remote_ip_location_city, context.remote_ip_location_region]
    |> Enum.reject(&blank?/1)
    |> Enum.join(", ")
    |> blank_to_nil()
  end

  defp obfuscated_remote_ip({a, b, _c, _d}) do
    "#{a}.#{b}.x.x"
  end

  defp obfuscated_remote_ip({a, b, c, d, _e, _f, _g, _h}) do
    [a, b, c, d]
    |> Enum.map(&Integer.to_string(&1, 16))
    |> Enum.map(&String.downcase/1)
    |> Enum.concat(["xxxx", "xxxx", "xxxx", "xxxx"])
    |> Enum.join(":")
  end

  defp blank?(value), do: value in [nil, ""]

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
