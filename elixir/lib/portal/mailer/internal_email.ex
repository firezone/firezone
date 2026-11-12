defmodule Portal.Mailer.InternalEmail do
  @moduledoc """
  Emails to the Firezone team rather than to customers, sent to the
  `FEEDBACK_EMAIL_RECIPIENT` address.
  """

  import Portal.Mailer
  import Swoosh.Email

  @survey_questions [
    {:referral_source, :referral_source_other, "How did you hear about Firezone?"},
    {:motivation, :motivation_other, "Why Firezone?"},
    {:use_case, :use_case_other, "Use case"},
    {:role, :role_other, "Role"}
  ]

  def enabled? do
    case Portal.Config.fetch_env!(:portal, __MODULE__)[:recipient] do
      recipient when is_binary(recipient) -> String.trim(recipient) != ""
      _ -> false
    end
  end

  def feedback_email(%Portal.Authentication.Subject{} = subject, message, url, screenshot \\ nil) do
    email =
      default_email()
      |> to(recipient())
      |> subject("In-portal feedback submission")
      |> text_body("""
      Account ID: #{subject.account.id}
      Actor ID: #{subject.actor.id}
      URL: #{url}

      #{message}
      """)

    if screenshot, do: attachment(email, screenshot), else: email
  end

  def sign_up_survey_email(%Portal.Account{} = account, %Portal.Actor{} = actor, survey) do
    account
    |> base_email(actor, "Sign-up questionnaire: #{account.name}")
    |> text_body("""
    Sign-up questionnaire

    Account: #{account.name} (#{account.id})
    Region: #{region()}
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

  def region_transfer_request_email(
        %Portal.Account{} = account,
        %Portal.Authentication.Subject{} = subject,
        from_region,
        to_region
      ) do
    default_email()
    |> to("support@firezone.dev")
    |> reply_to({subject.actor.name, subject.actor.email})
    |> subject("Region transfer request: #{account.name}")
    |> with_account_id(account.id)
    |> text_body("""
    Region transfer request

    Account: #{account.name} (#{account.id})
    Slug: #{account.slug}
    Plan: #{Portal.Billing.plan_type(account)}
    Requested by: #{subject.actor.name} <#{subject.actor.email}>

    From region: #{from_region}
    To region: #{to_region}
    """)
  end

  def sign_up_review_email(%{registration: registration} = review, recipient) do
    default_email()
    |> to(recipient)
    |> reply_to({registration.actor_name, registration.email})
    |> subject("Sign-up waiting for review: #{registration.company_name}")
    |> text_body("""
    Sign-up waiting for review

    The mail servers of this email domain are not on the list of known email providers,
    so the account is not created yet. An approver got a link to approve it.
    Reply to this email to contact the person.

    #{sign_up_review_details(review)}
    """)
  end

  def sign_up_approval_request_email(%{registration: registration} = review, approver, url) do
    default_email()
    |> to(approver)
    |> reply_to({registration.actor_name, registration.email})
    |> subject("Approve sign-up: #{registration.company_name}")
    |> text_body("""
    Sign-up waiting for your approval

    The mail servers of this email domain are not on the list of known email providers,
    so the account is not created yet.

    #{sign_up_review_details(review)}

    This link is only for you. It expires in 72 hours:
    #{url}
    """)
  end

  def sign_up_approved_email(%{registration: registration} = review, approvers, approved_by, account, domains) do
    trusted = if domains == [], do: "none", else: Enum.join(domains, ", ")

    default_email()
    |> to(approvers)
    |> subject("Sign-up approved: #{registration.company_name}")
    |> with_account_id(account.id)
    |> text_body("""
    Sign-up approved

    Approved by: #{approved_by}
    Account: #{account.name} (#{account.id})
    Newly trusted mail server domains: #{trusted}

    #{sign_up_review_details(review)}
    """)
  end

  def seats_overage_email(%Portal.Account{} = account, active_users_count) do
    limit = account.limits.monthly_active_users_count

    default_email()
    |> to(recipient())
    |> subject("Enterprise seat overage: #{account.name}")
    |> with_account_id(account.id)
    |> text_body("""
    Enterprise seat overage

    Account: #{account.name} (#{account.id})
    Slug: #{account.slug}

    Monthly active users: #{active_users_count}
    Seats in subscription: #{limit}
    Seats over: #{active_users_count - limit}

    Users are not blocked. This email repeats every 30 days while the account is over.
    """)
  end

  defp base_email(account, actor, subject) do
    default_email()
    |> to(recipient())
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
  defp recipient do
    Portal.Config.fetch_env!(:portal, __MODULE__) |> Keyword.fetch!(:recipient)
  end

  defp sign_up_review_details(%{registration: registration, mx_hosts: mx_hosts}) do
    hosts = if mx_hosts == [], do: "none found", else: Enum.join(mx_hosts, ", ")

    """
    Name: #{registration.actor_name} <#{registration.email}>
    Company: #{registration.company_name}
    Region: #{region()}
    Mail servers: #{hosts}\
    """
  end

  defp region do
    Portal.Config.fetch_env!(:portal, :data_residency_region)
    |> Atom.to_string()
    |> String.upcase()
  end
end
