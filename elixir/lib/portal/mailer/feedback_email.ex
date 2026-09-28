defmodule Portal.Mailer.FeedbackEmail do
  @moduledoc false

  import Portal.Mailer
  import Swoosh.Email

  def enabled? do
    case Portal.Config.fetch_env!(:portal, __MODULE__)[:recipient] do
      recipient when is_binary(recipient) -> String.trim(recipient) != ""
      _ -> false
    end
  end

  def feedback_email(%Portal.Authentication.Subject{} = subject, message, url, screenshot \\ nil) do
    recipient = Portal.Config.fetch_env!(:portal, __MODULE__) |> Keyword.fetch!(:recipient)

    email =
      default_email()
      |> to(recipient)
      |> subject("In-portal feedback submission")
      |> text_body("""
      Account ID: #{subject.account.id}
      Actor ID: #{subject.actor.id}
      URL: #{url}

      #{message}
      """)

    if screenshot, do: attachment(email, screenshot), else: email
  end
end
