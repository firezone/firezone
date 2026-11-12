defmodule Portal.Workers.SignUpReviewRequest do
  @moduledoc """
  Asks for a review of an email sign-up whose mail servers are not known.

  Each `SIGN_UP_REVIEW_APPROVERS` address gets its own job and email with a personal
  approval link and a reply-to of the person signing up, so a retry resends to one
  approver only. The link is made when the email is sent, so it is never stored in
  the job.

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
    Enum.reduce_while(approvers(), :ok, fn approver, :ok ->
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
  def perform(%Oban.Job{args: %{"review" => encrypted_review, "approver" => approver}}) do
    with true <- approver in approvers(),
         {:ok, review} <- PortalWeb.SignUpReview.decrypt_review(encrypted_review) do
      url = PortalWeb.SignUpReview.approval_url(encrypted_review, approver)

      review
      |> Mailer.InternalEmail.sign_up_approval_request_email(approver, url)
      |> Mailer.deliver()
      |> case do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      _removed_approver_or_expired -> :ok
    end
  end
end
