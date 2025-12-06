defmodule Web.Plugs.AutoRedirectDefaultProvider do
  @behaviour Plug

  use Web, :verified_routes

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias Domain.{
    Account,
    OIDC,
    Google,
    Okta,
    Entra,
    Safe
  }

  alias __MODULE__.DB

  @impl true
  def init(opts), do: opts

  @impl true
  def call(
        %{params: %{"as" => "client", "account_id_or_slug" => account_id_or_slug}} = conn,
        _opts
      ) do
    with %Account{} = account <- DB.get_account_by_id_or_slug(account_id_or_slug),
         provider when is_struct(provider) <- DB.get_default_provider_for_account(account) do
      redirect_path = redirect_path(account, provider)

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

  defmodule DB do
    import Ecto.Query

    alias Domain.{
      Account,
      OIDC,
      Okta,
      Google,
      Entra
    }

    def get_account_by_id_or_slug(id_or_slug) do
      case Ecto.UUID.cast(id_or_slug) do
        {:ok, _uuid} ->
          where(Account, [a], a.id == ^id_or_slug)

        :error ->
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
