defmodule PortalWeb.Plugs.AutoRedirectDefaultProvider do
  @behaviour Plug

  use PortalWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias Portal.{
    Account,
    OIDC,
    Google,
    Okta,
    Entra,
    Safe
  }

  alias __MODULE__.Database

  @impl true
  def init(opts), do: opts

  @impl true
  # Only redirect from the base sign-in page, not from provider-specific routes
  def call(
        %{
          params: %{"as" => as, "account_id_or_slug" => account_id_or_slug},
          path_info: [_account, "sign_in"]
        } = conn,
        _opts
      )
      when as in ["client", "gui-client", "headless-client"] do
    with %Account{} = account <- Database.get_account_by_id_or_slug(account_id_or_slug),
         provider when is_struct(provider) <- Database.get_default_provider_for_account(account) do
      sign_in_params = PortalWeb.Authentication.take_sign_in_params(conn.params)

      conn
      |> redirect(to: redirect_path(account, provider, sign_in_params))
      |> halt()
    else
      _ -> conn
    end
  end

  def call(conn, _opts) do
    conn
  end

  defp redirect_path(account, %OIDC.AuthProvider{} = provider, params) do
    ~p"/#{account}/sign_in/oidc/#{provider}?#{params}"
  end

  defp redirect_path(account, %Google.AuthProvider{} = provider, params) do
    ~p"/#{account}/sign_in/google/#{provider}?#{params}"
  end

  defp redirect_path(account, %Entra.AuthProvider{} = provider, params) do
    ~p"/#{account}/sign_in/entra/#{provider}?#{params}"
  end

  defp redirect_path(account, %Okta.AuthProvider{} = provider, params) do
    ~p"/#{account}/sign_in/okta/#{provider}?#{params}"
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.{
      Account,
      OIDC,
      Okta,
      Google,
      Entra
    }

    def get_account_by_id_or_slug(id_or_slug) do
      if Portal.Repo.valid_uuid?(id_or_slug) do
        where(Account, [a], a.id == ^id_or_slug)
      else
        where(Account, [a], a.slug == ^id_or_slug)
      end
      |> Safe.unscoped()
      |> Safe.one()
    end

    def get_default_provider_for_account(account) do
      account_id = account.id

      # Query each provider type separately to find the default
      providers = [
        {OIDC.AuthProvider, :oidc},
        {Google.AuthProvider, :google},
        {Entra.AuthProvider, :entra},
        {Okta.AuthProvider, :okta}
      ]

      Enum.find_value(providers, fn {schema, _type} ->
        from(p in schema,
          where: p.account_id == ^account_id and p.is_default == true and p.is_disabled == false,
          limit: 1
        )
        |> Safe.unscoped()
        |> Safe.one()
      end)
    end
  end
end
