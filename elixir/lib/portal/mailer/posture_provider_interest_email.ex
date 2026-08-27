defmodule Portal.Mailer.PostureProviderInterestEmail do
  @moduledoc false

  import Portal.Mailer
  import Swoosh.Email

  @support_email "support@firezone.dev"
  @subject "Posture Provider interest"

  def interest_email(%Portal.Authentication.Subject{} = subject, provider) do
    subject
    |> base_email()
    |> text_body("""
    Posture Provider Interest

    Actor ID: #{subject.actor.id}
    Account ID: #{subject.account.id}
    Provider: #{provider}
    """)
  end

  def feedback_email(%Portal.Authentication.Subject{} = subject, provider, feedback) do
    subject
    |> base_email()
    |> text_body("""
    Posture Provider Interest Feedback

    Actor ID: #{subject.actor.id}
    Account ID: #{subject.account.id}
    Provider: #{provider}

    Feedback:
    #{feedback}
    """)
  end

  defp base_email(subject) do
    default_email()
    |> subject(@subject)
    |> to(@support_email)
    |> with_account_id(subject.account.id)
  end
end
