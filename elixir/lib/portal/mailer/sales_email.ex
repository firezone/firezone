defmodule Portal.Mailer.SalesEmail do
  @moduledoc false

  import Portal.Mailer
  import Swoosh.Email

  @survey_questions [
    {:referral_source, :referral_source_other, "How did you hear about Firezone?"},
    {:motivation, :motivation_other, "Why Firezone?"},
    {:use_case, :use_case_other, "Use case"},
    {:role, :role_other, "Role"}
  ]

  def sign_up_survey_email(%Portal.Account{} = account, %Portal.Actor{} = actor, survey) do
    account
    |> base_email(actor, "Sign-up questionnaire: #{account.name}")
    |> text_body("""
    Sign-up questionnaire

    Account: #{account.name} (#{account.id})
    Actor: #{actor.name} <#{actor.email}>

    #{survey_answers(survey)}
    """)
  end

  def deletion_feedback_email(
        %Portal.Account{} = account,
        %Portal.Authentication.Subject{} = subject,
        feedback
      ) do
    account
    |> base_email(subject.actor, "Account deletion feedback: #{account.name}")
    |> text_body("""
    Account deletion feedback

    Account: #{account.name} (#{account.id})
    Actor: #{subject.actor.name} <#{subject.actor.email}>

    #{feedback}
    """)
  end

  defp base_email(account, actor, subject) do
    recipient = Portal.Config.fetch_env!(:portal, __MODULE__) |> Keyword.fetch!(:recipient)

    default_email()
    |> to(recipient)
    |> reply_to({actor.name, actor.email})
    |> subject(subject)
    |> with_account_id(account.id)
  end

  defp survey_answers(survey) do
    questions =
      Enum.map(@survey_questions, fn {field, other_field, label} ->
        "#{label} #{answer(survey, field, other_field)}"
      end)

    switching =
      if survey.switching do
        "Switching from another solution? Yes, from #{answer(survey, :previous_solution, :previous_solution_other)}"
      else
        "Switching from another solution? No"
      end

    Enum.join(questions ++ [switching], "\n")
  end

  defp answer(survey, field, other_field) do
    case Map.get(survey, field) do
      "other" -> "other (#{Map.get(survey, other_field)})"
      value -> value
    end
  end
end
