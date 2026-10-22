defmodule Portal.Mailer.PostureProviderInterestEmail do
  @moduledoc false

  import Portal.Mailer
  import Swoosh.Email

  @subject "Posture Provider interest"

  def enabled?, do: not is_nil(feedback_email_address())

  defp feedback_email_address do
    case Portal.Config.fetch_env!(:portal, __MODULE__)[:recipient] do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          address -> address
        end

      _ -> nil
    end
  end

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
    |> to(feedback_email_address())
    |> with_account_id(subject.account.id)
  end
end
