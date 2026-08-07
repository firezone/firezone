defmodule PortalWeb.SupportRequestController do
  @moduledoc """
  Handles the "Request Support" modal: emails the problem description to
  Firezone Support and optionally grants support access to the account for
  24 hours. Also handles ending an active support session.
  """
  use PortalWeb, :controller

  alias __MODULE__.Database
  alias PortalWeb.Session.Redirector

  require Logger

  def create(conn, %{"support_request" => %{"problem" => problem} = support_request} = params) do
    subject = conn.assigns.subject
    problem = String.trim(problem)
    grant_access? = support_request["grant_access"] == "true"

    cond do
      problem == "" ->
        conn
        |> put_flash(:error, "Please describe the problem you're seeing.")
        |> redirect_back(subject, params)

      grant_access? ->
        case Database.grant_support_access(subject) do
          {:ok, _provider} ->
            deliver_support_request(subject, problem, true)
            redirect_back(conn, subject, params)

          {:error, _changeset} ->
            conn
            |> put_flash(:error, "Support access is already active for this account.")
            |> redirect_back(subject, params)
        end

      true ->
        deliver_support_request(subject, problem, false)
        redirect_back(conn, subject, params)
    end
  end

  def create(conn, params) do
    conn
    |> put_flash(:error, "Invalid request.")
    |> redirect_back(conn.assigns.subject, params)
  end

  def end_support(conn, params) do
    subject = conn.assigns.subject

    case Database.revoke_support_access(subject) do
      {:ok, %{providers: providers}} when providers > 0 ->
        if Portal.Actor.support?(subject.actor) do
          conn
          |> PortalWeb.Cookie.Session.delete(subject.account.id)
          |> put_flash(:info, "Support session ended. You have been signed out.")
          |> redirect(to: ~p"/#{subject.account.slug}/sign_in")
        else
          conn
          |> put_flash(:success, "Support session ended.")
          |> redirect_back(subject, params)
        end

      _other ->
        conn
        |> put_flash(:info, "Support access is not active.")
        |> redirect_back(subject, params)
    end
  end

  defp deliver_support_request(subject, problem, access_granted?) do
    Portal.Mailer.SupportEmail.support_request_email(
      subject.account,
      subject.actor,
      problem,
      access_granted?
    )
    |> Portal.Mailer.deliver_with_rate_limit(
      rate_limit_key: {:support_request, subject.account.id},
      rate_limit: 5,
      rate_limit_interval: :timer.minutes(60)
    )
    |> case do
      {:ok, _metadata} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to deliver support request email",
          account_id: subject.account.id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp redirect_back(conn, subject, params) do
    path = Redirector.sanitize_redirect_to(subject.account, params["redirect_to"], subject.actor)
    redirect(conn, to: path)
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe
    alias Portal.{Actor, AuthProvider, FirezoneSupport}

    def grant_support_access(subject) do
      id = Ecto.UUID.generate()

      expires_at =
        DateTime.utc_now()
        |> DateTime.add(FirezoneSupport.AuthProvider.access_window_secs(), :second)

      Safe.transact(fn ->
        changeset =
          %FirezoneSupport.AuthProvider{}
          |> Ecto.Changeset.change(
            id: id,
            account_id: subject.account.id,
            expires_at: expires_at
          )
          |> Ecto.Changeset.put_assoc(:auth_provider, %AuthProvider{
            id: id,
            account_id: subject.account.id,
            type: :firezone_support
          })

        with {:ok, provider} <- changeset |> Safe.scoped(subject) |> Safe.insert(),
             {:ok, _job} <-
               Oban.insert(
                 Portal.Workers.DeleteExpiredSupportAccess.new(
                   %{"account_id" => subject.account.id, "auth_provider_id" => id},
                   scheduled_at: expires_at
                 )
               ) do
          {:ok, provider}
        end
      end)
    end

    def revoke_support_access(subject) do
      if Actor.support?(subject.actor) do
        revoke_own_support_access(subject.account.id)
      else
        Safe.transact(fn ->
          {providers, _} =
            from(ap in AuthProvider, where: ap.type == :firezone_support)
            |> Safe.scoped(subject)
            |> Safe.delete_all()

          {actors, _} =
            from(a in Actor, where: a.type == :firezone_support)
            |> Safe.scoped(subject)
            |> Safe.delete_all()

          {:ok, %{providers: providers, actors: actors}}
        end)
      end
    end

    # Support actors are denied writes to auth providers and actors, so ending
    # their own session deletes only support artifacts via unscoped queries
    defp revoke_own_support_access(account_id) do
      Safe.transact(fn ->
        {providers, _} =
          from(ap in AuthProvider,
            where: ap.account_id == ^account_id,
            where: ap.type == :firezone_support
          )
          |> Safe.unscoped()
          |> Safe.delete_all()

        {actors, _} =
          from(a in Actor,
            where: a.account_id == ^account_id,
            where: a.type == :firezone_support
          )
          |> Safe.unscoped()
          |> Safe.delete_all()

        {:ok, %{providers: providers, actors: actors}}
      end)
    end
  end
end
