defmodule FzHttpWeb.Authentication do
  @moduledoc """
  Authentication helpers.
  """
  use Guardian, otp_app: :fz_http

  alias FzHttp.Configurations, as: Conf
  alias FzHttp.Telemetry
  alias FzHttp.Users
  alias FzHttp.Users.User
  alias FzHttpWeb.Router.Helpers, as: Routes

  import FzHttpWeb.OIDC.Helpers

  @guardian_token_name "guardian_default_token"

  def subject_for_token(resource, _claims) do
    {:ok, to_string(resource.id)}
  end

  def resource_from_claims(%{"sub" => id}) do
    case Users.get_user(id) do
      nil -> {:error, :resource_not_found}
      user -> {:ok, user}
    end
  end

  @doc """
  Authenticates a user against a password hash. Only makes sense
  for local auth.
  """
  def authenticate(%User{} = user, password) when is_binary(password) do
    if user.password_hash do
      authenticate(
        user,
        password,
        Argon2.verify_pass(password, user.password_hash)
      )
    else
      {:error, :invalid_credentials}
    end
  end

  def authenticate(_user, _password) do
    authenticate(nil, nil, Argon2.no_user_verify())
  end

  defp authenticate(user, _password, true) do
    {:ok, user}
  end

  defp authenticate(_user, _password, false) do
    {:error, :invalid_credentials}
  end

  def sign_in(conn, user, auth) do
    Telemetry.login()
    Users.update_last_signed_in(user, auth)
    %{provider: provider} = auth

    conn =
      with :identity <- provider,
           true <- FzHttp.MFA.exists?(user) do
        Plug.Conn.put_session(conn, "mfa_required_at", DateTime.utc_now())
      else
        _ -> conn
      end
      |> Plug.Conn.put_session("login_method", provider)

    __MODULE__.Plug.sign_in(conn, user)
  end

  def sign_out(conn, and_then \\ fn c -> c end) do
    with {:ok, provider_key} <- parse_provider(Plug.Conn.get_session(conn, "login_method")),
         {:ok, provider} <- atomize_provider(provider_key),
         {:ok, client_id} <-
           parse_client_id(Conf.get!(:parsed_openid_connect_providers)[provider]),
         {:ok, token} <- parse_token(Plug.Conn.get_session(conn, "id_token")),
         {:ok, end_session_uri} <-
           parse_end_session_uri(
             openid_connect().end_session_uri(provider, %{
               client_id: client_id,
               id_token_hint: token,
               post_logout_redirect_uri: Routes.root_url(conn, :index)
             })
           ) do
      conn
      |> __MODULE__.Plug.sign_out()
      |> Phoenix.Controller.redirect(external: end_session_uri)
    else
      _ ->
        conn
        |> __MODULE__.Plug.sign_out()
        |> and_then.()
    end
  end

  defp parse_provider(nil), do: {:error, "provider not present"}
  defp parse_provider(p) when is_binary(p), do: {:ok, p}
  defp parse_provider(p) when is_atom(p), do: {:ok, "#{p}"}

  defp parse_client_id(nil), do: {:error, "client_id missing"}
  defp parse_client_id(c), do: {:ok, c[:client_id]}

  defp parse_token(nil), do: {:error, "token missing"}
  defp parse_token(t), do: {:ok, t}

  defp parse_end_session_uri(nil), do: {:error, "end_session_uri missing"}
  defp parse_end_session_uri(e), do: {:ok, e}

  def get_current_user(%Plug.Conn{} = conn) do
    __MODULE__.Plug.current_resource(conn)
  end

  def get_current_user(%{@guardian_token_name => token} = _session) do
    case Guardian.resource_from_token(__MODULE__, token) do
      {:ok, resource, _claims} ->
        resource

      {:error, _reason} ->
        nil
    end
  end
end
