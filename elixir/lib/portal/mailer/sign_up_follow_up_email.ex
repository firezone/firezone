defmodule Portal.Mailer.SignUpFollowUpEmail do
  @moduledoc false

  import Portal.Mailer
  import Swoosh.Email

  use Phoenix.VerifiedRoutes,
    endpoint: PortalWeb.Endpoint,
    router: PortalWeb.Router,
    statics: PortalWeb.static_paths()

  @from_name "Jamil Bou Kheir"

  def follow_up_email(%Portal.Actor{account: %Portal.Account{} = account} = actor, config, stage \\ "welcome") do
    {subject, paragraphs} = content(stage)
    unsubscribe_url =
      url(~p"/#{actor.account_id}/unsubscribe/#{Portal.UnsubscribeToken.sign(actor, :product_feedback_requests)}")

    new()
    |> from({@from_name, Keyword.fetch!(config, :from_email)})
    |> to(actor.email)
    |> maybe_bcc(config[:bcc_email])
    |> subject(subject)
    |> with_account_id(account.id)
    |> text_body(Enum.join(paragraphs, "\n\n") <> "\n\nTurn off these notifications: #{unsubscribe_url}\n")
    |> html_body(
      Enum.map_join(paragraphs, &"<p>#{Plug.HTML.html_escape(&1)}</p>") <>
        "<p><a href=\"#{Plug.HTML.html_escape(unsubscribe_url)}\">Turn off these notifications</a></p>"
    )
  end

  defp content("welcome") do
    {"Need a hand getting started?", [
      "Hi there,",
      "I'm Jamil, one of Firezone's founders.",
      "Thanks for signing up! Wanted to reach out and see what you're hoping to accomplish with Firezone.",
      "Need any help getting set up? Just reply here and I'm happy to help.",
      "Jamil"
    ]}
  end

  defp content("feedback") do
    {"How's Firezone working out?", [
      "Hi there,",
      "Just checking in to see how things are going with Firezone.",
      "What's working well? Anything that's been frustrating or could be better?",
      "We take feedback seriously, so I'd love to hear your thoughts.",
      "Jamil"
    ]}
  end

  defp maybe_bcc(email, bcc_email) when is_binary(bcc_email), do: bcc(email, bcc_email)
  defp maybe_bcc(email, _bcc_email), do: email
end
