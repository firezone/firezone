defmodule Portal.Workers.SignUpReviewRequest do
  @moduledoc """
  Asks for a review of an email sign-up whose mail servers are not known.

  Each `SIGN_UP_REVIEW_APPROVERS` address gets its own job and email with a personal
  approval link, so a retry resends to one approver only. The link is made when the
  email is sent, so it is never stored in the job. The optional
  `SIGN_UP_REVIEW_EMAIL_RECIPIENT` copy has no link and a reply-to of the person
  signing up.

  The jobs hold the encrypted sign-up because no account exists yet. One request per
  email address is sent per 24 hours, so opening the verification link again does not
  send more.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 10,
    unique: [period: 86_400, keys: [:email, :approver]]

  alias Portal.Mailer

  @doc "Approver addresses, lowercased. Review is off when there are none."
  def approvers do
    Portal.Config.get_env(:portal, __MODULE__, [])
    |> Keyword.get(:approvers, [])
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def enabled?, do: approvers() != []

  def enqueue(email, encrypted_review) do
    recipients = if recipient(), do: [nil | approvers()], else: approvers()

    Enum.reduce_while(recipients, :ok, fn approver, :ok ->
      %{"email" => email, "approver" => approver, "review" => encrypted_review}
      |> new()
      |> Oban.insert()
      |> case do
        {:ok, _job} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"review" => encrypted_review} = args}) do
    case PortalWeb.SignUpReview.decrypt_review(encrypted_review) do
      {:ok, review} -> deliver(review, encrypted_review, args["approver"])
      :error -> :ok
    end
  end

  defp deliver(review, _encrypted_review, nil) do
    case recipient() do
      nil ->
        :ok

      recipient ->
        review
        |> Mailer.InternalEmail.sign_up_review_email(recipient)
        |> send_email()
    end
  end

  defp deliver(review, encrypted_review, approver) do
    if approver in approvers() do
      url = PortalWeb.SignUpReview.approval_url(encrypted_review, approver)

      review
      |> Mailer.InternalEmail.sign_up_approval_request_email(approver, url)
      |> send_email()
    else
      :ok
    end
  end

  defp send_email(email) do
    case Mailer.deliver(email) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp recipient do
    case Portal.Config.get_env(:portal, __MODULE__, [])[:recipient] do
      recipient when is_binary(recipient) ->
        if String.trim(recipient) == "", do: nil, else: String.trim(recipient)

      _ ->
        nil
    end
  end
end
