defmodule PortalWeb.AcceptanceCase.Vault do
  use Wallaby.DSL
  import Portal.AuthProviderFixtures

  @vault_root_token "firezone"
  @vault_endpoint "http://127.0.0.1:8200"

  def ensure_userpass_auth_enabled do
    request(:put, "sys/auth/userpass", %{"type" => "userpass"})
    :ok
  end

  def upsert_user(username, email, password) do
    :ok = ensure_userpass_auth_enabled()

    :ok =
      request(:put, "auth/userpass/users/#{username}", %{
        password: password,
        token_policies: "oidc-auth",
        token_ttl: "1h"
      })

    # User Entity and Entity Alias are created automatically when user logs-in for
    # the first time
    {:ok, {200, params}} =
      request(:post, "auth/userpass/login/#{username}", %{password: password})

    entity_id = params["auth"]["entity_id"]

    :ok =
      request(:put, "identity/entity/id/#{entity_id}", %{
        metadata: %{email: email, name: username}
      })

    {:ok, entity_id}
  end

  # Note: this code is not safe from race conditions because provider name is not unique per test case
  def setup_oidc_provider(account, endpoint_url) do
    :ok =
      request(:put, "identity/oidc/client/firezone", %{
        assignments: "allow_all",
        scopes_supported: "openid,email,groups,name"
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
        "identity/oidc/scope/name",
        %{template: Base.encode64("{\"name\": {{identity.entity.metadata.name}}}")}
      )

    :ok =
      request(
        :put,
        "identity/oidc/scope/groups",
        %{template: Base.encode64("{\"groups\": {{identity.entity.groups.names}}}")}
      )

    :ok =
      request(
        :put,
        "identity/oidc/provider/default",
        %{scopes_supported: "email,name,groups"}
      )

    {:ok, {200, params}} = request(:get, "identity/oidc/client/firezone")

    provider =
      oidc_provider_fixture(
        name: "Vault",
        discovery_document_uri:
          "#{@vault_endpoint}/v1/identity/oidc/provider/default/.well-known/openid-configuration",
        client_id: params["data"]["client_id"],
        client_secret: params["data"]["client_secret"],
        response_type: "code",
        scope: "openid email name offline_access",
        account: account
      )

    :ok =
      request(:put, "identity/oidc/client/firezone", %{
        redirect_uris:
          "#{endpoint_url}/#{account.id}/sign_in/providers/#{provider.id}/handle_callback"
      })

    provider
  end

  def userpass_flow(session, oidc_login, oidc_password) do
    session
    |> fill_in(Query.css("[data-test-select=\"auth-method\"]"), with: "userpass")
    |> fill_in(Query.fillable_field("username"), with: oidc_login)
    |> fill_in(Query.fillable_field("password"), with: oidc_password)
    |> click(Query.button("Sign In"))
  end

  defp request(method, path, params_or_body \\ nil) do
    content_type =
      if method == :patch,
        do: "application/merge-patch+json",
        else: "application/octet-stream"

    headers = [
      {"X-Vault-Request", "true"},
      {"X-Vault-Token", @vault_root_token},
      {"Content-Type", content_type}
    ]

    body =
      cond do
        is_map(params_or_body) ->
          JSON.encode!(params_or_body)

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
        {:ok, {status, JSON.decode!(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
