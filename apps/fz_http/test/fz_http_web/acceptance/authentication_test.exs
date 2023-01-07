defmodule FzHttpWeb.Acceptance.AuthenticationTest do
  use FzHttpWeb.AcceptanceCase, async: true
  alias FzHttp.UsersFixtures

  describe "using login and password" do
    feature "renders error on invalid login or password", %{session: session} do
      session
      |> visit(~p"/")
      |> click(Query.link("Sign in with email"))
      |> fill_in(Query.fillable_field("Email"), with: "foo@bar.com")
      |> fill_in(Query.fillable_field("Password"), with: "firezone1234")
      |> click(Query.button("Sign In"))
      |> assert_error_flash(
        "Error signing in: user credentials are invalid or user does not exist"
      )
    end

    feature "renders error on invalid password", %{session: session} do
      user = UsersFixtures.create_user()

      session
      |> visit(~p"/")
      |> click(Query.link("Sign in with email"))
      |> fill_in(Query.fillable_field("Email"), with: user.email)
      |> fill_in(Query.fillable_field("Password"), with: "firezone1234")
      |> click(Query.button("Sign In"))
      |> assert_error_flash(
        "Error signing in: user credentials are invalid or user does not exist"
      )
      |> assert_unauthenticated()
    end

    feature "redirects to /users after successful log in as admin", %{session: session} do
      password = "firezone1234"
      user = UsersFixtures.create_user(password: password, password_confirmation: password)

      session =
        session
        |> visit(~p"/")
        |> click(Query.link("Sign in with email"))
        |> fill_in(Query.fillable_field("Email"), with: user.email)
        |> fill_in(Query.fillable_field("Password"), with: password)
        |> click(Query.button("Sign In"))

      assert current_path(session) == "/users"

      assert_authenticated session, user
    end

    feature "redirects to /users after successful log in as unprivileged user", %{
      session: session
    } do
      password = "firezone1234"

      user =
        UsersFixtures.create_user_with_role(
          [password: password, password_confirmation: password],
          :unprivileged
        )

      session =
        session
        |> visit(~p"/")
        |> click(Query.link("Sign in with email"))
        |> fill_in(Query.fillable_field("Email"), with: user.email)
        |> fill_in(Query.fillable_field("Password"), with: password)
        |> click(Query.button("Sign In"))

      assert current_path(session) == "/user_devices"

      assert_authenticated session, user
    end

    feature "creates a user from OIDC provider", %{session: session} do
      {name, email, password} = setup_vault_as_oidc()

      session =
        session
        |> visit(~p"/")
        |> click(Query.link("OIDC Vault"))
        |> assert_text("Method")
        |> fill_in(Query.css("#select-ember40"), with: "userpass")
        |> fill_in(Query.fillable_field("username"), with: name)
        |> fill_in(Query.fillable_field("password"), with: password)
        |> click(Query.button("Sign In"))
        |> find(Query.text("Your Devices"), fn _ -> :ok end)

      assert current_path(session) == "/user_devices"

      assert user = FzHttp.Repo.one(FzHttp.Users.User)
      assert user.email == email
      assert user.role == :unprivileged
      assert user.last_signed_in_method == "vault"
    end

    feature "authenticates existing user via OIDC provider", %{session: session} do
      user = UsersFixtures.create_user()
      {name, email, password} = setup_vault_as_oidc(user.email)

      session =
        session
        |> visit(~p"/")
        |> click(Query.link("OIDC Vault"))
        |> assert_text("Method")
        |> fill_in(Query.css("#select-ember40"), with: "userpass")
        |> fill_in(Query.fillable_field("username"), with: name)
        |> fill_in(Query.fillable_field("password"), with: password)
        |> click(Query.button("Sign In"))
        |> find(Query.text("Users", count: 2), fn _ -> :ok end)

      assert current_path(session) == "/users"

      assert user = FzHttp.Repo.one(FzHttp.Users.User)
      assert user.email == email
      assert user.role == :admin
      assert user.last_signed_in_method == "vault"
    end
  end

  defp setup_vault_as_oidc(email \\ "foo@bar.com") do
    vault_request(:put, "sys/auth/userpass", %{"type" => "userpass"})

    vault_request(:put, "auth/userpass/users/firezone", %{
      "password" => "firezone1234",
      "token_policies" => "email"
    })

    vault_request(:get, "auth/userpass/users/firezone")

    vault_request(:put, "identity/oidc/client/firezone", %{
      "assignments" => "allow_all",
      "redirect_uris" => @endpoint.url <> "/auth/oidc/vault/callback/",
      "scopes_supported" => "openid,user,groups,email,metadata,metadata.email"
    })

    vault_request(
      :put,
      "identity/oidc/scope/email",
      %{template: Base.encode64("{\"email\": {{identity.entity.metadata.email}}}")}
    )

    vault_request(
      :put,
      "identity/oidc/provider/default",
      %{scopes_supported: "email"}
    )

    {:ok, {200, params}} =
      vault_request(
        :list,
        "identity/entity-alias/id"
      )

    entity_id =
      params["data"]["key_info"]
      |> Enum.find(fn {_, key_info} -> key_info["name"] == "firezone" end)
      |> elem(1)
      |> Map.fetch!("canonical_id")

    vault_request(
      :put,
      "identity/entity/id/#{entity_id}",
      %{metadata: %{email: email}}
    )

    assert {:ok, {200, params}} = vault_request(:get, "identity/oidc/client/firezone")

    FzHttp.Configurations.put!(
      :openid_connect_providers,
      [
        %{
          "id" => "vault",
          "discovery_document_uri" =>
            "http://127.0.0.1:8200/v1/identity/oidc/provider/default/.well-known/openid-configuration",
          "client_id" => params["data"]["client_id"],
          "client_secret" => params["data"]["client_secret"],
          "redirect_uri" => @endpoint.url <> "/auth/oidc/vault/callback/",
          "response_type" => "code",
          "scope" => "openid email profile offline_access",
          "label" => "OIDC Vault"
        }
      ]
    )

    # XXX: Test and prod env should not be so different during app startup
    FzHttp.OIDC.StartProxy.start_link(:prod)

    {"firezone", email, "firezone1234"}
  end

  defp vault_request(method, path, params_or_body \\ nil) do
    headers = [
      {"X-Vault-Request", "true"},
      {"X-Vault-Token", "firezone"}
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

    :hackney.request(method, "http://127.0.0.1:8200/v1/" <> path, headers, body, [:with_body])
    |> case do
      {:ok, _status, _headers, ""} ->
        :ok

      {:ok, status, _headers, body} ->
        {:ok, {status, Jason.decode!(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp assert_error_flash(session, text) do
    assert_text(session, Query.css(".flash-error"), text)
    session
  end
end
