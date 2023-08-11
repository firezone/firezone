defmodule Web.Mailer.AuthEmail do
  use Web, :html
  import Swoosh.Email
  import Web.Mailer

  embed_templates "auth_email/*.html", suffix: "_html"
  embed_templates "auth_email/*.text", suffix: "_text"

  def sign_in_link_email(%Domain.Auth.Identity{} = identity, params \\ %{}) do
    params =
      Map.merge(params, %{
        identity_id: identity.id,
        secret: identity.provider_virtual_state.sign_in_token
      })

    sign_in_link =
      url(
        ~p"/#{identity.account_id}/sign_in/providers/#{identity.provider_id}/verify_sign_in_token?#{params}"
      )

    default_email()
    |> subject("Firezone Sign In Link")
    |> to(identity.provider_identifier)
    |> render_body(__MODULE__, :sign_in_link, link: sign_in_link)
  end
end
