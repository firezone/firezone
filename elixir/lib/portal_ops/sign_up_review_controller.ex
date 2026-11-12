defmodule PortalOps.SignUpReviewController do
  @moduledoc """
  The review page for email sign-ups held by `PortalWeb.SignUpReview`. It is only on the
  ops endpoint, so approvers must reach the ops hostname to use their links.

  Opening the page changes nothing, so mail scanners that open links cannot act. The
  approver approves or denies the sign-up, and can add the selected mail server domains
  to the allow list or the deny list. Approving creates the account. Either decision is
  sent to all approvers. Only domains derived from the sign-up's own unknown MX hosts can
  be added, a listed domain keeps its verdict, and a sign-up with a denied MX host can
  not be approved.
  """
  use Phoenix.Controller, formats: [:html]
  import Plug.Conn
  alias __MODULE__.Database
  alias Portal.Workers.SignUpReviewRequest
  alias PortalWeb.SignUpReview
  require Logger

  # Second-level labels under which a "parent" domain would be a public suffix.
  @public_second_levels ~w[ac co com edu go gov ne net or org]

  def show(conn, params) do
    case SignUpReview.verify_approval(params["token"]) do
      {:ok, review, _approver} -> render_review(conn, review, params["token"], nil)
      :error -> invalid(conn)
    end
  end

  def decide(conn, params) do
    with {:ok, review, approver} <- SignUpReview.verify_approval(params["token"]),
         {:ok, decision, verdict} <- decision(params["decision"]) do
      suggested = suggested_domains(review.mail_servers)
      domains =
        if verdict do
          params |> Map.get("domains", []) |> List.wrap() |> Enum.filter(&(&1 in suggested))
        else
          []
        end

      case decide(decision, review, approver, verdict, domains) do
        {:ok, :denied} ->
          render(conn, :denied, review: review, domains: domains)

        {:ok, account} ->
          render(conn, :approved, review: review, account: account, domains: domains)

        {:error, :denied_mail_server} ->
          render_review(conn, review, params["token"], "A mail server of this sign-up is now denied.")

        {:error, {:account_exists, _accounts}} ->
          render(conn, :exists, review: review)

        {:error, message} when is_binary(message) ->
          render_review(conn, review, params["token"], message)

        {:error, _reason} ->
          render_review(conn, review, params["token"], "Could not save the decision. Please try again.")
      end
    else
      :error -> invalid(conn)
    end
  end

  defp render_review(conn, review, token, error) do
    render(conn, :show,
      review: review,
      token: token,
      suggested_domains: suggested_domains(review.mail_servers),
      error: error
    )
  end

  defp invalid(conn) do
    conn
    |> put_status(:not_found)
    |> render(:invalid)
  end

  defp decision("approve_and_allow"), do: {:ok, :approve, :allow}
  defp decision("approve"), do: {:ok, :approve, nil}
  defp decision("deny_and_deny"), do: {:ok, :deny, :deny}
  defp decision("deny"), do: {:ok, :deny, nil}
  defp decision(_decision), do: :error

  defp decide(:approve, review, approver, verdict, domains) do
    with :ok <- refuse_denied(review.mail_servers),
         :ok <- Database.insert_domains(domains, verdict),
         {:ok, result} <-
           PortalWeb.SignUp.complete_email_sign_up(review.registration, review.user_agent, review.real_ip) do
      Logger.info("Sign-up approved",
        account_id: result.account.id,
        approved_by: approver,
        allowed_domains: Enum.join(domains, ",")
      )

      approvers = SignUpReviewRequest.approvers()

      review
      |> Portal.Mailer.InternalEmail.sign_up_approved_email(approvers, approver, result.account, domains)
      |> Portal.Mailer.enqueue()
      |> log_enqueue_error()

      {:ok, result.account}
    end
  end

  defp decide(:deny, review, approver, verdict, domains) do
    with :ok <- Database.insert_domains(domains, verdict) do
      Logger.info("Sign-up denied",
        email_domain: review.registration.email |> String.split("@") |> List.last(),
        denied_by: approver,
        denied_domains: Enum.join(domains, ",")
      )

      review
      |> Portal.Mailer.InternalEmail.sign_up_denied_email(SignUpReviewRequest.approvers(), approver, domains)
      |> Portal.Mailer.deliver()
      |> log_enqueue_error()

      {:ok, :denied}
    end
  end

  # A sign-up denied together with its domains stays denied, as every review link
  # works until it expires.
  defp refuse_denied(mail_servers) do
    hosts = Enum.map(mail_servers, fn {host, _verdict} -> host end)

    if Database.any_denied?(hosts) do
      {:error, :denied_mail_server}
    else
      :ok
    end
  end

  defp log_enqueue_error({:ok, _result}), do: :ok

  defp log_enqueue_error({:error, reason}) do
    Logger.error("Failed to send sign-up decision email", reason: inspect(reason))
  end

  # Unknown hosts minus their first label, so "mx1.example.com" suggests "example.com".
  # The host itself is suggested when its parent would be a public suffix like "co.uk".
  defp suggested_domains(mail_servers) do
    for {host, :unknown} <- mail_servers,
        Regex.match?(Portal.KnownMxDomain.format(), host),
        uniq: true,
        do: parent_domain(host)
  end

  defp parent_domain(host) do
    case String.split(host, ".") do
      [_first | [second_level, _tld] = parent] when second_level not in @public_second_levels ->
        Enum.join(parent, ".")

      [_first, _second, _third, _fourth | _rest] = labels ->
        labels |> tl() |> Enum.join(".")

      _labels ->
        host
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    def any_denied?(hosts) do
      domains = Enum.flat_map(hosts, &PortalWeb.SignUpReview.label_suffixes/1)

      from(d in Portal.KnownMxDomain, where: d.domain in ^domains and d.verdict == :deny)
      |> Safe.unscoped()
      |> Safe.exists?()
    end

    def insert_domains(domains, verdict) do
      Enum.reduce_while(domains, :ok, fn domain, :ok ->
        %Portal.KnownMxDomain{}
        |> Ecto.Changeset.cast(%{domain: domain, verdict: verdict}, [:domain, :verdict])
        |> Portal.KnownMxDomain.changeset()
        |> Safe.unscoped()
        |> Safe.insert(on_conflict: :nothing)
        |> case do
          {:ok, _known_mx_domain} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end
end
