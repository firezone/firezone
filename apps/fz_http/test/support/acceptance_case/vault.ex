defmodule FzHttpWeb.AcceptanceCase.Vault do
  use Wallaby.DSL

  @vault_root_token "firezone"
  @vault_endpoint "http://127.0.0.1:8200"

  def ensure_userpass_auth_enabled do
    request(:put, "sys/auth/userpass", %{"type" => "userpass"})
    :ok
  end

  def upsert_user(username, email, password) do
    :ok = ensure_userpass_auth_enabled()

    :ok = request(:put, "auth/userpass/users/#{username}", %{password: password})

    # User Entity and Entity Alias are created automatically when user logs-in for
    # the first time
    {:ok, {200, params}} =
      request(:post, "auth/userpass/login/#{username}", %{password: password})

    entity_id = params["auth"]["entity_id"]

    :ok = request(:put, "identity/entity/id/#{entity_id}", %{metadata: %{email: email}})

    :ok
  end

  def setup_oidc_provider(endpoint_url, attrs_overrides \\ %{"auto_create_users" => true}) do
    :ok =
      request(:put, "identity/oidc/client/firezone", %{
        assignments: "allow_all",
        redirect_uris: "#{endpoint_url}/auth/oidc/vault/callback/",
        scopes_supported: "openid,email"
      })

    :ok =
      request(
        :put,
        "identity/oidc/scope/email",
        %{template: Base.encode64("{\"email\": {{identity.entity.metadata.email}}}")}
      )

    :ok =
      request(
        :put,
        "identity/oidc/provider/default",
        %{scopes_supported: "email"}
      )

    {:ok, {200, params}} = request(:get, "identity/oidc/client/firezone")

    FzHttp.Config.put_config!(
      :openid_connect_providers,
      [
        %{
          "id" => "vault",
          "discovery_document_uri" =>
            "http://127.0.0.1:8200/v1/identity/oidc/provider/default/.well-known/openid-configuration",
          "client_id" => params["data"]["client_id"],
          "client_secret" => params["data"]["client_secret"],
          "redirect_uri" => "#{endpoint_url}/auth/oidc/vault/callback/",
          "response_type" => "code",
          "scope" => "openid email offline_access",
          "label" => "OIDC Vault"
        }
        |> Map.merge(attrs_overrides)
      ]
    )

    :ok
  end

  def userpass_flow(session, oidc_login, oidc_password) do
    session
    |> assert_text("Method")
    |> fill_in(Query.css("#select-ember40"), with: "userpass")
    |> fill_in(Query.fillable_field("username"), with: oidc_login)
    |> fill_in(Query.fillable_field("password"), with: oidc_password)
    |> click(Query.button("Sign In"))
  end

  defp request(method, path, params_or_body \\ nil) do
    headers = [
      {"X-Vault-Request", "true"},
      {"X-Vault-Token", @vault_root_token}
    ]

    body =
      cond do
        is_map(params_or_body) ->
          Jason.encode!(params_or_body)

        is_binary(params_or_body) ->
          params_or_body

        true ->
          ""
      end

    :hackney.request(method, "#{@vault_endpoint}/v1/#{path}", headers, body, [:with_body])
    |> case do
      {:ok, _status, _headers, ""} ->
        :ok

      {:ok, status, _headers, body} ->
        {:ok, {status, Jason.decode!(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
