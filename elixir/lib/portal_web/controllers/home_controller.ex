defmodule PortalWeb.HomeController do
  use PortalWeb, :controller

  @doc """
  Shows no page of its own. Clients, and people who have signed in from this browser
  before, go to the sign-in chooser. Accounts that no longer exist don't count. Everyone else is most likely new, so they go to
  sign-up, which links to sign-in for people on a new browser.
  """
  @spec home(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def home(conn, params) do
    recent_account_ids = PortalWeb.Plugs.PruneRecentAccounts.account_ids(conn)
    sign_in_params = PortalWeb.Authentication.take_sign_in_params(params)

    if recent_account_ids != [] || PortalWeb.Authentication.client_sign_in?(sign_in_params) do
      redirect(conn, to: ~p"/sign_in?#{sign_in_params}")
    else
      redirect(conn, to: ~p"/sign_up?#{PortalWeb.Authentication.take_analytics_params(params)}")
    end
  end

  # Kept so links to the pages this replaced keep working.
  @spec getting_started(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def getting_started(conn, params) do
    redirect(conn, to: ~p"/?#{PortalWeb.Authentication.take_sign_in_params(params)}")
  end

  @spec find_account(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def find_account(conn, params) do
    redirect(conn, to: ~p"/sign_in?#{PortalWeb.Authentication.take_sign_in_params(params)}")
  end

  @doc """
  Forgets one account from the recent accounts on this browser and goes back to the
  sign-in chooser. Ids that aren't in the cookie change nothing.
  """
  @spec remove_recent_account(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def remove_recent_account(conn, %{"account_id" => account_id} = params) when is_binary(account_id) do
    conn
    |> forget_recent_account(Ecto.UUID.cast(account_id))
    |> redirect(to: ~p"/sign_in?#{PortalWeb.Authentication.take_sign_in_params(params)}")
  end

  defp forget_recent_account(conn, {:ok, account_id}) do
    %PortalWeb.Cookie.RecentAccounts{account_ids: recent_account_ids} =
      PortalWeb.Cookie.RecentAccounts.fetch(conn)

    if account_id in recent_account_ids,
      do: PortalWeb.Cookie.RecentAccounts.remove(conn, [account_id]),
      else: conn
  end

  defp forget_recent_account(conn, :error), do: conn

  @spec redirect_to_sign_in(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def redirect_to_sign_in(conn, %{"account_id_or_slug" => account_id_or_slug} = params)
      when is_binary(account_id_or_slug) do
    params = PortalWeb.Authentication.take_sign_in_params(params)

    case account_id_or_slug |> from_pasted_url() |> validate_account_id_or_slug() do
      {:ok, account_id_or_slug} ->
        redirect(conn, to: ~p"/#{account_id_or_slug}/sign_in?#{params}")

      {:error, reason} ->
        conn
        |> put_flash(:error, reason)
        |> redirect(to: ~p"/sign_in?#{params}")
    end
  end

  @slug_regex ~r/^[a-zA-Z0-9_]+$/

  # People paste the sign-in URL from the email, e.g. "https://app.firezone.dev/acme" or
  # "app.firezone.dev/acme/sign_in", so take the first path segment after the host.
  defp from_pasted_url(input) do
    segments = input |> String.trim() |> String.replace(~r{^[a-zA-Z]+://}, "") |> String.split("/", trim: true)

    case segments do
      [host, account | _rest] -> if host?(host), do: account, else: host
      [single] -> single
      [] -> ""
    end
  end

  defp host?(segment), do: String.contains?(segment, [".", ":"]) or segment == "localhost"

  defp validate_account_id_or_slug(account_id_or_slug) do
    cond do
      Portal.Repo.valid_uuid?(account_id_or_slug) ->
        {:ok, String.downcase(account_id_or_slug)}

      String.match?(account_id_or_slug, @slug_regex) ->
        {:ok, String.downcase(account_id_or_slug)}

      true ->
        {:error, "Sign-in URLs can only contain letters, digits and underscores"}
    end
  end
end
