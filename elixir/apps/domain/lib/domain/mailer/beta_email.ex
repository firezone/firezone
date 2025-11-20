defmodule Domain.Mailer.BetaEmail do
  import Swoosh.Email
  import Domain.Mailer
  import Phoenix.Template, only: [embed_templates: 2]

  embed_templates "beta_email/*.text", suffix: "_text"

  def rest_api_beta_email(
        %Domain.Accounts.Account{} = account,
        %Domain.Auth.Subject{} = subject
      ) do
    default_email()
    |> subject("REST API Beta Request - #{account.slug}")
    |> to("support@firezone.dev")
    |> reply_to(identity_to_reply_to(subject.identity))
    |> render_text_body(__MODULE__, :rest_api_request,
      account: account,
      subject: subject
    )
  end

  defp identity_to_reply_to(nil), do: "notifications@firezone.dev"

  defp identity_to_reply_to(%Domain.Auth.Identity{} = identity), do: identity.actor.email
end
