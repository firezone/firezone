defmodule Portal.Mailer.FeedbackEmail do
  @moduledoc false

  import Portal.Mailer
  import Swoosh.Email

  def feedback_email(%Portal.Authentication.Subject{} = subject, message, url, screenshot \\ nil) do
    email =
      default_email()
      |> to("support@firezone.dev")
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
