defmodule PortalOps.SignUpReviewController do
  @moduledoc """
  The review page for email sign-ups held by `PortalWeb.SignUpReview`. It is only on the
  ops endpoint, so approvers must reach the ops hostname to use their links.

  Opening the page changes nothing, so mail scanners that open links cannot approve.
  Approving trusts the selected mail server domains, creates the account and tells all
  approvers. Only domains derived from the sign-up's own unknown MX hosts can be trusted,
  and a denied domain is never changed to allowed.
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

  def approve(conn, params) do
    with {:ok, review, approver} <- SignUpReview.verify_approval(params["token"]) do
      suggested = suggested_domains(review.mail_servers)
      domains = params |> Map.get("domains", []) |> List.wrap() |> Enum.filter(&(&1 in suggested))

      case approve_sign_up(review, approver, domains) do
        {:ok, account} ->
          render(conn, :approved, review: review, account: account)

        {:error, {:account_exists, _accounts}} ->
          render(conn, :exists, review: review)

        {:error, message} when is_binary(message) ->
          render_review(conn, review, params["token"], message)

        {:error, _reason} ->
          render_review(conn, review, params["token"], "Could not approve the sign-up. Please try again.")
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

  defp approve_sign_up(review, approver, domains) do
    with :ok <- Database.insert_allowed(domains),
         {:ok, result} <-
           PortalWeb.SignUp.complete_email_sign_up(review.registration, review.user_agent, review.real_ip) do
      Logger.info("Sign-up approved",
        account_id: result.account.id,
        approved_by: approver,
        trusted_domains: Enum.join(domains, ",")
      )

      send_approved_email(review, approver, result.account, domains)
      {:ok, result.account}
    end
  end

  defp send_approved_email(review, approver, account, domains) do
    review
    |> Portal.Mailer.InternalEmail.sign_up_approved_email(
      SignUpReviewRequest.approvers(),
      approver,
      account,
      domains
    )
    |> Portal.Mailer.enqueue()
    |> case do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to enqueue sign-up approved email",
          account_id: account.id,
          reason: inspect(reason)
        )
    end
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
    alias Portal.Safe

    def insert_allowed(domains) do
      Enum.reduce_while(domains, :ok, fn domain, :ok ->
        %Portal.KnownMxDomain{}
        |> Ecto.Changeset.cast(%{domain: domain, verdict: :allow}, [:domain, :verdict])
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
