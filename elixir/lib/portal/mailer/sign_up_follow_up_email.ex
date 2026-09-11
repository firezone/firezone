defmodule Portal.Mailer.SignUpFollowUpEmail do
  @moduledoc false

  import Portal.Mailer
  import Swoosh.Email

  @from_name "Jamil Bou Kheir"
  @subject "Tell me what you think of Firezone"

  @paragraphs [
    "Hi there,",
    "I'm Jamil, Firezone's founder.",
    "I noticed you recently signed up for an account. Can I answer any questions or help you get set up?",
    "How's it working for you so far? Initial thoughts?",
    "I read every reply and do my best to respond. Thanks so much!",
    "Jamil"
  ]

  def follow_up_email(%Portal.Actor{account: %Portal.Account{} = account} = actor, config) do
    new()
    |> from({@from_name, Keyword.fetch!(config, :from_email)})
    |> to(actor.email)
    |> maybe_bcc(config[:bcc_email])
    |> subject(@subject)
    |> with_account_id(account.id)
    |> text_body(Enum.join(@paragraphs, "\n\n") <> "\n")
    |> html_body(Enum.map_join(@paragraphs, &"<p>#{Plug.HTML.html_escape(&1)}</p>"))
  end

  defp maybe_bcc(email, bcc_email) when is_binary(bcc_email), do: bcc(email, bcc_email)
  defp maybe_bcc(email, _bcc_email), do: email
end
