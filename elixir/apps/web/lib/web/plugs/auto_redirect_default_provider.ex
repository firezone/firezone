defmodule Web.Plugs.AutoRedirectDefaultProvider do
  @behaviour Plug

  use Web, :verified_routes

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias Domain.{
    Accounts.Account,
    OIDC,
    Google,
    Okta,
    Entra,
    Safe
  }

  @impl true
  def init(opts), do: opts

  @impl true
  def call(
        %{params: %{"as" => "client", "account_id_or_slug" => account_id_or_slug}} = conn,
        _opts
      ) do
    with %Account{} = account <- get_account_by_id_or_slug(account_id_or_slug),
         provider when is_struct(provider) <- get_default_provider_for_account(account) do
      redirect_path = ~p"/#{account}/sign_in/providers/#{provider}/redirect"

      # Append original query params
      full_redirect_path =
        if conn.query_string != "" do
          redirect_path <> "?" <> conn.query_string
        else
          redirect_path
        end

      conn
      |> redirect(to: full_redirect_path)
      |> halt()
    else
      _ -> conn
    end
  end

  # Non-client sign in
  def call(conn, _opts) do
    conn
  end

  defp get_account_by_id_or_slug(id_or_slug) do
    Query.by_id_or_slug(id_or_slug)
    |> Safe.unscoped()
    |> Safe.one()
  end

  defp get_default_provider_for_account(account) do
    Query.default_provider_for_account_id(account.id)
    |> Safe.unscoped()
    |> Safe.one()
  end

  defp redirect_path(account, %OIDC.AuthProvider{} = provider) do
    ~p"/#{account}/sign_in/oidc/#{provider}"
  end

  defp redirect_path(account, %Google.AuthProvider{} = provider) do
    ~p"/#{account}/sign_in/google/#{provider}"
  end

  defp redirect_path(account, %Entra.AuthProvider{} = provider) do
    ~p"/#{account}/sign_in/entra/#{provider}"
  end

  defp redirect_path(account, %Okta.AuthProvider{} = provider) do
    ~p"/#{account}/sign_in/okta/#{provider}"
  end

  defmodule Query do
    import Ecto.Query

    alias Domain.{
      Accounts.Account,
      OIDC,
      Okta,
      Google,
      Entra
    }

    def by_id_or_slug(id_or_slug) do
      case Ecto.UUID.cast(id_or_slug) do
        {:ok, _uuid} ->
          where(Account, [a], a.id == ^id_or_slug)

        :error ->
          where(Account, [a], a.slug == ^id_or_slug)
      end
    end

    def default_provider_for_account_id(account_id) do
      # Check each provider type for is_default = true
      # OIDC providers
      oidc_query =
        from(p in OIDC.AuthProvider,
          where: p.account_id == ^account_id and p.is_default == true and p.is_disabled == false,
          limit: 1
        )

      # Google providers
      google_query =
        from(p in Google.AuthProvider,
          where: p.account_id == ^account_id and p.is_default == true and p.is_disabled == false,
          limit: 1
        )

      # Entra providers
      entra_query =
        from(p in Entra.AuthProvider,
          where: p.account_id == ^account_id and p.is_default == true and p.is_disabled == false,
          limit: 1
        )

      # Okta providers
      okta_query =
        from(p in Okta.AuthProvider,
          where: p.account_id == ^account_id and p.is_default == true and p.is_disabled == false,
          limit: 1
        )

      # Union all queries to find the default provider across all types
      from(q in subquery(oidc_query), select: q)
      |> union(^from(q in subquery(google_query), select: q))
      |> union(^from(q in subquery(entra_query), select: q))
      |> union(^from(q in subquery(okta_query), select: q))
      |> limit(1)
    end
  end
end
