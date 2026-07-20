defmodule Portal.AuthenticationTest do
  use Portal.DataCase, async: true
  import Portal.Authentication
  import Portal.TokenFixtures
  import Portal.SubjectFixtures
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures
  import Portal.DeviceFixtures
  import Portal.GatewaySessionFixtures
  import Portal.SiteFixtures
  alias Portal.Authentication
  alias Portal.ClientToken

  describe "create_non_interactive_client_token/3" do
    test "returns valid client token for a given service account" do
      account = account_fixture()
      service_account = actor_fixture(account: account, type: :service_account)
      admin_subject = admin_subject_fixture(account: account)

      one_day = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)

      assert {:ok, token} =
               create_non_interactive_client_token(
                 service_account,
                 %{expires_at: one_day},
                 admin_subject
               )

      encoded_token = encode_fragment!(token)
      context = build_context(type: :client)
      assert {:ok, subject} = authenticate(encoded_token, context)
      assert subject.account.id == account.id
      assert subject.actor.id == service_account.id
      assert subject.context.type == :client

      assert db_token = Repo.get_by(ClientToken, id: subject.credential.id)
      assert db_token.account_id == account.id
      assert db_token.actor_id == service_account.id
      assert DateTime.truncate(db_token.expires_at, :second) == one_day
    end

    test "token can be used multiple times" do
      account = account_fixture()
      service_account = actor_fixture(account: account, type: :service_account)
      admin_subject = admin_subject_fixture(account: account)
      expires_at = DateTime.add(DateTime.utc_now(), 1, :day)

      assert {:ok, token} =
               create_non_interactive_client_token(
                 service_account,
                 %{expires_at: expires_at},
                 admin_subject
               )

      encoded_token = encode_fragment!(token)
      context = build_context(type: :client)

      # Use token multiple times
      assert {:ok, _} = authenticate(encoded_token, context)
      assert {:ok, _} = authenticate(encoded_token, context)
      assert {:ok, _} = authenticate(encoded_token, context)
    end

    test "raises an error when trying to create a token for a different account" do
      service_account = actor_fixture(type: :service_account)
      admin_subject = admin_subject_fixture()
      expires_at = DateTime.add(DateTime.utc_now(), 1, :day)

      assert_raise FunctionClauseError, fn ->
        create_non_interactive_client_token(
          service_account,
          %{expires_at: expires_at},
          admin_subject
        )
      end
    end

    test "creates a token for a regular account_user" do
      account = account_fixture()
      regular_user = actor_fixture(account: account, type: :account_user)
      admin_subject = admin_subject_fixture(account: account)
      expires_at = DateTime.add(DateTime.utc_now(), 1, :day)

      assert {:ok, token} =
               create_non_interactive_client_token(
                 regular_user,
                 %{expires_at: expires_at},
                 admin_subject
               )

      assert token.actor_id == regular_user.id
      assert token.account_id == account.id
      assert is_nil(token.auth_provider_id)
    end

    test "creates a token for an account_admin_user" do
      account = account_fixture()
      admin_user = actor_fixture(account: account, type: :account_admin_user)
      admin_subject = admin_subject_fixture(account: account)
      expires_at = DateTime.add(DateTime.utc_now(), 1, :day)

      assert {:ok, token} =
               create_non_interactive_client_token(
                 admin_user,
                 %{expires_at: expires_at},
                 admin_subject
               )

      assert token.actor_id == admin_user.id
      assert token.account_id == account.id
      assert is_nil(token.auth_provider_id)
    end

    test "raises for api_client actor type" do
      account = account_fixture()
      api_client = actor_fixture(account: account, type: :api_client)
      admin_subject = admin_subject_fixture(account: account)

      assert_raise FunctionClauseError, fn ->
        create_non_interactive_client_token(api_client, %{}, admin_subject)
      end
    end
  end

  describe "create_api_token/3" do
    test "returns valid api_client token for a given api_client actor" do
      account = account_fixture()
      api_client = actor_fixture(account: account, type: :api_client)
      admin_subject = admin_subject_fixture(account: account)

      one_day = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)

      assert {:ok, encoded_token} =
               create_api_token(
                 api_client,
                 %{"name" => "test-token", "expires_at" => one_day},
                 admin_subject
               )

      context = build_context(type: :api_client)
      assert {:ok, subject} = authenticate(encoded_token, context)
      assert subject.account.id == account.id
      assert subject.actor.id == api_client.id
      assert subject.context.type == :api_client

      assert token = Repo.get_by(Portal.APIToken, id: subject.credential.id)
      assert token.name == "test-token"
      assert token.account_id == account.id
      assert token.actor_id == api_client.id
      assert DateTime.truncate(token.expires_at, :second) == one_day
    end

    test "token can be used multiple times" do
      account = account_fixture()
      api_client = actor_fixture(account: account, type: :api_client)
      admin_subject = admin_subject_fixture(account: account)
      expires_at = DateTime.utc_now() |> DateTime.add(30, :day)

      assert {:ok, encoded_token} =
               create_api_token(api_client, %{expires_at: expires_at}, admin_subject)

      context = build_context(type: :api_client)

      # Use token multiple times
      assert {:ok, _} = authenticate(encoded_token, context)
      assert {:ok, _} = authenticate(encoded_token, context)
      assert {:ok, _} = authenticate(encoded_token, context)
    end

    test "raises an error when trying to create a token for a different account" do
      api_client = actor_fixture(type: :api_client)
      admin_subject = admin_subject_fixture()

      assert_raise FunctionClauseError, fn ->
        create_api_token(api_client, %{}, admin_subject)
      end
    end

    test "raises an error when trying to create a token not for an api_client" do
      account = account_fixture()
      regular_user = actor_fixture(account: account, type: :account_user)
      admin_subject = admin_subject_fixture(account: account)

      assert_raise FunctionClauseError, fn ->
        create_api_token(regular_user, %{}, admin_subject)
      end
    end

    test "raises for service_account actor type" do
      account = account_fixture()
      service_account = actor_fixture(account: account, type: :service_account)
      admin_subject = admin_subject_fixture(account: account)

      assert_raise FunctionClauseError, fn ->
        create_api_token(service_account, %{}, admin_subject)
      end
    end

    test "raises for account_admin_user actor type" do
      account = account_fixture()
      admin_user = actor_fixture(account: account, type: :account_admin_user)
      admin_subject = admin_subject_fixture(account: account)

      assert_raise FunctionClauseError, fn ->
        create_api_token(admin_user, %{}, admin_subject)
      end
    end
  end

  describe "authenticate/2" do
    test "returns error when token is invalid" do
      context = build_context(type: :client)

      assert authenticate("invalid.token", context) == {:error, :invalid_token}
      assert authenticate("foo", context) == {:error, :invalid_token}
      assert authenticate(".invalid", context) == {:error, :invalid_token}
    end

    test "returns error for empty token" do
      context = build_context(type: :client)
      assert authenticate("", context) == {:error, :invalid_token}
    end

    test "returns error for token with only nonce" do
      context = build_context(type: :client)
      assert authenticate("justnonce.", context) == {:error, :invalid_token}
    end

    test "returns error for token with only fragment" do
      context = build_context(type: :client)
      assert authenticate(".justfragment", context) == {:error, :invalid_token}
    end

    test "returns error when token is issued for a different context type" do
      client_encoded = encode_token(client_token_fixture())
      api_client_encoded = encode_api_token(api_token_fixture())

      client_context = build_context(type: :client)
      api_client_context = build_context(type: :api_client)

      # Client token used with api_client context
      assert authenticate(client_encoded, api_client_context) == {:error, :invalid_token}
      # API client token used with client context
      assert authenticate(api_client_encoded, client_context) == {:error, :invalid_token}
    end

    test "returns error when client token used with api_client context" do
      encoded = encode_token(client_token_fixture())
      context = build_context(type: :api_client)
      assert authenticate(encoded, context) == {:error, :invalid_token}
    end

    test "returns error when api_client token used with client context" do
      encoded = encode_api_token(api_token_fixture())
      context = build_context(type: :client)
      assert authenticate(encoded, context) == {:error, :invalid_token}
    end

    test "returns error when nonce is invalid" do
      encoded = encode_token(client_token_fixture(secret_nonce: "correct"))
      context = build_context(type: :client)

      # Replace correct nonce with wrong one
      wrong_nonce_token = "wrong" <> String.slice(encoded, 7..-1//1)
      assert authenticate(wrong_nonce_token, context) == {:error, :invalid_token}
    end

    test "returns error when nonce is empty but expected non-empty" do
      encoded = encode_token(client_token_fixture(secret_nonce: "nonempty"))
      context = build_context(type: :client)

      # Remove the nonce entirely
      [_nonce, fragment] = String.split(encoded, ".", parts: 2)
      empty_nonce_token = "." <> fragment
      assert authenticate(empty_nonce_token, context) == {:error, :invalid_token}
    end

    test "returns subject for client token" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      token = client_token_fixture(account: account, actor: actor)
      encoded = encode_token(token)

      context = build_context(type: :client)

      assert {:ok, subject} = authenticate(encoded, context)
      assert subject.actor.id == actor.id
      assert subject.account.id == account.id
      assert subject.credential.id == token.id
      assert subject.expires_at == token.expires_at
    end

    test "returns subject for api_client token" do
      account = account_fixture()
      actor = actor_fixture(account: account, type: :api_client)

      token = api_token_fixture(account: account, actor: actor)
      encoded = encode_api_token(token)

      context = build_context(type: :api_client)

      assert {:ok, subject} = authenticate(encoded, context)
      assert subject.actor.id == actor.id
      assert subject.account.id == account.id
      assert subject.credential.id == token.id
    end

    test "returns subject for service account token" do
      account = account_fixture()
      service_account = actor_fixture(account: account, type: :service_account)
      admin_subject = admin_subject_fixture(account: account)
      expires_at = DateTime.add(DateTime.utc_now(), 1, :day)

      assert {:ok, token} =
               create_non_interactive_client_token(
                 service_account,
                 %{expires_at: expires_at},
                 admin_subject
               )

      encoded_token = encode_fragment!(token)
      context = build_context(type: :client)
      assert {:ok, subject} = authenticate(encoded_token, context)
      assert subject.actor.id == service_account.id
      assert subject.account.id == account.id
    end

    test "does not update last_seen fields on client token (recorded on devices)" do
      encoded = encode_token(client_token_fixture())

      context =
        build_context(
          type: :client,
          remote_ip: {192, 168, 1, 100},
          remote_ip_location_region: "UA",
          remote_ip_location_city: "Kyiv",
          remote_ip_location_lat: 50.45,
          remote_ip_location_lon: 30.52,
          user_agent: "Test/1.0"
        )

      assert {:ok, subject} = authenticate(encoded, context)

      # Client tokens no longer track last_seen_* — session data is stored on the device
      updated_token = Repo.get_by(ClientToken, id: subject.credential.id)
      assert is_nil(updated_token.last_used_device)
    end

    test "returns error when actor is deleted" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      encoded = encode_token(client_token_fixture(account: account, actor: actor))

      Portal.Repo.delete!(actor)

      context = build_context(type: :client)
      assert authenticate(encoded, context) == {:error, :invalid_token}
    end

    test "returns error when actor is disabled" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      encoded = encode_token(client_token_fixture(account: account, actor: actor))

      actor
      |> Ecto.Changeset.change(disabled_at: DateTime.utc_now())
      |> Portal.Repo.update!()

      context = build_context(type: :client)
      assert authenticate(encoded, context) == {:error, :invalid_token}
    end

    test "returns error for client token when account is disabled" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      encoded = encode_token(client_token_fixture(account: account, actor: actor))

      account
      |> Ecto.Changeset.change(disabled_at: DateTime.utc_now())
      |> Portal.Repo.update!()

      context = build_context(type: :client)
      assert authenticate(encoded, context) == {:error, :invalid_token}
    end

    test "returns error when token is expired" do
      token =
        client_token_fixture(expires_at: DateTime.add(DateTime.utc_now(), -3600, :second))

      encoded = encode_token(token)
      context = build_context(type: :client)
      assert authenticate(encoded, context) == {:error, :invalid_token}
    end

    test "returns error when token expired just now" do
      token =
        client_token_fixture(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))

      encoded = encode_token(token)
      context = build_context(type: :client)
      assert authenticate(encoded, context) == {:error, :invalid_token}
    end

    test "succeeds when token expires in the future" do
      token =
        client_token_fixture(expires_at: DateTime.add(DateTime.utc_now(), 3600, :second))

      encoded = encode_token(token)
      context = build_context(type: :client)
      assert {:ok, _subject} = authenticate(encoded, context)
    end

    test "returns error when token does not exist in database" do
      # Create and then delete the token
      token = client_token_fixture()
      encoded = encode_token(token)
      Repo.delete!(token)

      context = build_context(type: :client)
      assert authenticate(encoded, context) == {:error, :invalid_token}
    end

    test "returns error when fragment is tampered with" do
      encoded = encode_token(client_token_fixture())
      context = build_context(type: :client)

      # Tamper with the fragment part
      [nonce, fragment] = String.split(encoded, ".", parts: 2)
      tampered = nonce <> "." <> fragment <> "tampered"
      assert authenticate(tampered, context) == {:error, :invalid_token}
    end

    test "handles IPv6 addresses in context" do
      encoded = encode_token(client_token_fixture())

      context =
        build_context(
          type: :client,
          remote_ip: {0, 0, 0, 0, 0, 0, 0, 1}
        )

      assert {:ok, subject} = authenticate(encoded, context)
      assert subject.context.remote_ip == {0, 0, 0, 0, 0, 0, 0, 1}
    end

    test "handles various user agent strings" do
      encoded = encode_token(client_token_fixture())

      user_agent = String.duplicate("M", 255)

      context =
        build_context(
          type: :client,
          user_agent: user_agent
        )

      assert {:ok, subject} = authenticate(encoded, context)
      assert subject.context.user_agent == user_agent
    end

    test "subject contains auth_provider_id when present on token" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      auth_provider = auth_provider_fixture(account: account)

      token = client_token_fixture(account: account, actor: actor, auth_provider: auth_provider)
      encoded = encode_token(token)
      context = build_context(type: :client)

      assert {:ok, subject} = authenticate(encoded, context)
      assert subject.credential.auth_provider_id == auth_provider.id
    end
  end

  describe "create_interactive_client_token/1" do
    test "creates a client token with required attributes" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      auth_provider = auth_provider_fixture(account: account)

      attrs = %{
        account_id: account.id,
        actor_id: actor.id,
        auth_provider_id: auth_provider.id,
        secret_nonce: "testnonce",
        expires_at: DateTime.add(DateTime.utc_now(), 1, :day)
      }

      assert {:ok, token} = create_interactive_client_token(attrs)
      assert token.__struct__ == ClientToken
      assert token.account_id == account.id
      assert token.actor_id == actor.id
      assert token.secret_salt != nil
      assert token.secret_hash != nil
      assert token.secret_fragment != nil
    end

    test "fails to create client token without actor_id" do
      account = account_fixture()
      auth_provider = auth_provider_fixture(account: account)

      attrs = %{
        account_id: account.id,
        auth_provider_id: auth_provider.id,
        secret_nonce: "",
        expires_at: DateTime.add(DateTime.utc_now(), 1, :day)
      }

      assert {:error, changeset} = create_interactive_client_token(attrs)
      assert "can't be blank" in errors_on(changeset).actor_id
    end

    test "fails to create client token without auth_provider_id" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      attrs = %{
        account_id: account.id,
        actor_id: actor.id,
        secret_nonce: "",
        expires_at: DateTime.add(DateTime.utc_now(), 1, :day)
      }

      assert {:error, changeset} = create_interactive_client_token(attrs)
      assert "can't be blank" in errors_on(changeset).auth_provider_id
    end

    test "fails when nonce contains period" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      auth_provider = auth_provider_fixture(account: account)

      attrs = %{
        account_id: account.id,
        actor_id: actor.id,
        auth_provider_id: auth_provider.id,
        secret_nonce: "invalid.nonce"
      }

      assert {:error, changeset} = create_interactive_client_token(attrs)
      assert errors_on(changeset).secret_nonce != []
    end

    test "fails when nonce is too long" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      auth_provider = auth_provider_fixture(account: account)

      attrs = %{
        account_id: account.id,
        actor_id: actor.id,
        auth_provider_id: auth_provider.id,
        secret_nonce: String.duplicate("a", 129)
      }

      assert {:error, changeset} = create_interactive_client_token(attrs)
      assert errors_on(changeset).secret_nonce != []
    end

    test "allows nonce at maximum length" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      auth_provider = auth_provider_fixture(account: account)

      attrs = %{
        account_id: account.id,
        actor_id: actor.id,
        auth_provider_id: auth_provider.id,
        secret_nonce: String.duplicate("a", 128),
        expires_at: DateTime.add(DateTime.utc_now(), 1, :day)
      }

      assert {:ok, _token} = create_interactive_client_token(attrs)
    end

    test "creates an api token for api_client actor" do
      account = account_fixture()
      api_client = actor_fixture(account: account, type: :api_client)
      admin_subject = admin_subject_fixture(account: account)
      expires_at = DateTime.utc_now() |> DateTime.add(30, :day)

      assert {:ok, encoded_token} =
               create_api_token(api_client, %{expires_at: expires_at}, admin_subject)

      assert is_binary(encoded_token)
    end

    test "fails to create api token without expires_at" do
      account = account_fixture()
      api_client = actor_fixture(account: account, type: :api_client)
      admin_subject = admin_subject_fixture(account: account)

      assert {:error, changeset} = create_api_token(api_client, %{}, admin_subject)
      assert "can't be blank" in errors_on(changeset).expires_at
    end

    test "creates a relay token" do
      assert {:ok, token} = create_relay_token()
      assert token.id != nil
      assert token.secret_fragment != nil
      assert token.secret_hash != nil
      assert token.secret_salt != nil
    end

    test "creates a gateway token" do
      account = account_fixture()
      site = site_fixture(account: account)
      subject = admin_subject_fixture(account: account)

      assert {:ok, token} = create_gateway_token(site, subject)
      assert token.id != nil
      assert token.account_id == account.id
      assert token.site_id == site.id
      assert token.secret_fragment != nil
      assert token.secret_hash != nil
      assert token.secret_salt != nil
    end

    test "non-admin user cannot create gateway token" do
      account = account_fixture()
      site = site_fixture(account: account)
      subject = subject_fixture(account: account, actor: %{type: :account_user})

      assert {:error, :unauthorized} = create_gateway_token(site, subject)
    end

    test "creates a single-owner gateway token for a gateway" do
      account = account_fixture()
      gateway = gateway_fixture(account: account)
      subject = admin_subject_fixture(account: account)

      assert {:ok, token} = create_gateway_token(gateway, subject)
      assert token.account_id == account.id
      assert token.device_id == gateway.id
      assert is_nil(token.site_id)
      assert is_nil(token.rotated_at)
      assert token.secret_fragment != nil
      assert Portal.GatewayToken.single_owner?(token)
    end

    test "returns error when the gateway already has an active token" do
      account = account_fixture()
      gateway = gateway_fixture(account: account)
      subject = admin_subject_fixture(account: account)

      assert {:ok, _token} = create_gateway_token(gateway, subject)
      assert {:error, changeset} = create_gateway_token(gateway, subject)
      assert {:device_id, {"has already been taken", _}} = hd(changeset.errors)
    end

    test "non-admin user cannot create single-owner gateway token" do
      account = account_fixture()
      gateway = gateway_fixture(account: account)
      subject = subject_fixture(account: account, actor: %{type: :account_user})

      assert {:error, :unauthorized} = create_gateway_token(gateway, subject)
    end
  end

  describe "rotate_gateway_token/2" do
    test "with no existing token acts as create" do
      account = account_fixture()
      gateway = gateway_fixture(account: account)
      subject = admin_subject_fixture(account: account)

      assert {:ok, token} = rotate_gateway_token(gateway, subject)
      assert token.device_id == gateway.id
      assert is_nil(token.rotated_at)
      assert token.secret_fragment != nil
    end

    test "stamps an in-use active token and mints a new one" do
      account = account_fixture()
      gateway = gateway_fixture(account: account)
      subject = admin_subject_fixture(account: account)

      {:ok, old_token} = create_gateway_token(gateway, subject)
      gateway_session_fixture(account: account, gateway: gateway, token: old_token)

      assert {:ok, new_token} = rotate_gateway_token(gateway, subject)

      assert new_token.id != old_token.id
      assert is_nil(new_token.rotated_at)

      old_token = Repo.get_by!(Portal.GatewayToken, account_id: account.id, id: old_token.id)
      assert old_token.rotated_at != nil
    end

    test "replaces a never-used active token instead of stamping it" do
      account = account_fixture()
      gateway = gateway_fixture(account: account)
      subject = admin_subject_fixture(account: account)

      {:ok, old_token} = create_gateway_token(gateway, subject)
      assert {:ok, new_token} = rotate_gateway_token(gateway, subject)

      assert new_token.id != old_token.id
      assert is_nil(new_token.rotated_at)

      # No session ever referenced the old token, so it is gone outright
      refute Repo.get_by(Portal.GatewayToken, account_id: account.id, id: old_token.id)
    end

    test "re-rotating replaces the pending token and keeps the rotated deadline" do
      account = account_fixture()
      gateway = gateway_fixture(account: account)
      subject = admin_subject_fixture(account: account)

      {:ok, in_use_token} = create_gateway_token(gateway, subject)
      gateway_session_fixture(account: account, gateway: gateway, token: in_use_token)
      {:ok, pending_token} = rotate_gateway_token(gateway, subject)

      in_use_token =
        Repo.get_by!(Portal.GatewayToken, account_id: account.id, id: in_use_token.id)

      original_rotated_at = in_use_token.rotated_at

      assert {:ok, replacement_token} = rotate_gateway_token(gateway, subject)

      # The unconfirmed pending token is gone, replaced by the new one
      refute Repo.get_by(Portal.GatewayToken, account_id: account.id, id: pending_token.id)
      assert is_nil(replacement_token.rotated_at)

      # The in-use rotated token keeps its original deadline
      in_use_token =
        Repo.get_by!(Portal.GatewayToken, account_id: account.id, id: in_use_token.id)

      assert in_use_token.rotated_at == original_rotated_at
    end

    test "with only a rotated token mints a new active token" do
      account = account_fixture()
      gateway = gateway_fixture(account: account)
      subject = admin_subject_fixture(account: account)

      {:ok, old_token} = create_gateway_token(gateway, subject)
      gateway_session_fixture(account: account, gateway: gateway, token: old_token)
      {:ok, pending_token} = rotate_gateway_token(gateway, subject)

      # Simulate confirmation racing ahead: only the rotated token remains
      Portal.GatewayToken
      |> Repo.get_by!(account_id: account.id, id: pending_token.id)
      |> Repo.delete!()

      assert {:ok, new_token} = rotate_gateway_token(gateway, subject)
      assert is_nil(new_token.rotated_at)

      old_token = Repo.get_by!(Portal.GatewayToken, account_id: account.id, id: old_token.id)
      assert old_token.rotated_at != nil
    end

    test "non-admin user cannot rotate gateway token" do
      account = account_fixture()
      gateway = gateway_fixture(account: account)
      subject = subject_fixture(account: account, actor: %{type: :account_user})

      assert {:error, :unauthorized} = rotate_gateway_token(gateway, subject)
    end
  end

  describe "verify_gateway_token/1 with single-owner tokens" do
    test "verifies an active single-owner token" do
      gateway = gateway_fixture()
      token = gateway_token_fixture(gateway: gateway)

      assert {:ok, verified} = verify_gateway_token(encode_fragment!(token))
      assert verified.id == token.id
      assert verified.device_id == gateway.id
    end

    test "verifies a rotated token within the grace period" do
      gateway = gateway_fixture()
      token = gateway_token_fixture(gateway: gateway, rotated_at: DateTime.utc_now())

      assert {:ok, _verified} = verify_gateway_token(encode_fragment!(token))
    end

    test "rejects a rotated token past the grace period" do
      gateway = gateway_fixture()
      rotated_at = DateTime.add(DateTime.utc_now(), -5, :hour)
      token = gateway_token_fixture(gateway: gateway, rotated_at: rotated_at)

      assert {:error, :invalid_token} = verify_gateway_token(encode_fragment!(token))
    end

    test "first use of the replacement token deletes the rotated sibling" do
      gateway = gateway_fixture()
      rotated = gateway_token_fixture(gateway: gateway, rotated_at: DateTime.utc_now())
      active = gateway_token_fixture(gateway: gateway)

      assert {:ok, _verified} = verify_gateway_token(encode_fragment!(active))

      refute Repo.get_by(Portal.GatewayToken, account_id: rotated.account_id, id: rotated.id)
    end

    test "using the rotated token does not delete the active sibling" do
      gateway = gateway_fixture()
      rotated = gateway_token_fixture(gateway: gateway, rotated_at: DateTime.utc_now())
      active = gateway_token_fixture(gateway: gateway)

      assert {:ok, _verified} = verify_gateway_token(encode_fragment!(rotated))

      assert Repo.get_by(Portal.GatewayToken, account_id: active.account_id, id: active.id)
      assert Repo.get_by(Portal.GatewayToken, account_id: rotated.account_id, id: rotated.id)
    end

    test "verifying an active token with no sibling reports none" do
      gateway = gateway_fixture()
      token = gateway_token_fixture(gateway: gateway)

      assert {:ok, verified} = verify_gateway_token(encode_fragment!(token))
      assert is_nil(verified.rotated_sibling_id)
    end

    test "multi-owner site tokens never see each other as siblings" do
      account = account_fixture()
      site = site_fixture(account: account)
      token_1 = gateway_token_fixture(account: account, site: site)
      token_2 = gateway_token_fixture(account: account, site: site)

      assert {:ok, verified} = verify_gateway_token(encode_fragment!(token_1))
      assert is_nil(verified.rotated_sibling_id)

      assert Repo.get_by(Portal.GatewayToken, account_id: account.id, id: token_2.id)
    end
  end

  describe "one-time passcodes and portal sessions" do
    test "creates a one-time passcode" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      assert {:ok, passcode} = create_one_time_passcode(account, actor)
      assert passcode.id != nil
      assert passcode.account_id == account.id
      assert passcode.actor_id == actor.id
      assert passcode.code != nil
      assert String.length(passcode.code) == 6
      assert passcode.code_hash != nil
      assert passcode.expires_at != nil
    end

    test "creates a one-time passcode for disabled account" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      account
      |> Ecto.Changeset.change(disabled_at: DateTime.utc_now())
      |> Portal.Repo.update!()

      assert {:ok, passcode} = create_one_time_passcode(account, actor)
      assert passcode.id != nil
      assert passcode.account_id == account.id
    end

    test "verifies a valid one-time passcode" do
      account = account_fixture()
      actor = actor_fixture(account: account, allow_email_otp_sign_in: true)

      {:ok, passcode} = create_one_time_passcode(account, actor)

      assert {:ok, verified_passcode} =
               verify_one_time_passcode(account.id, actor.id, passcode.id, passcode.code)

      assert verified_passcode.id == passcode.id
      assert verified_passcode.actor_id == actor.id
    end

    test "fails to verify one-time passcode with wrong code" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      {:ok, passcode} = create_one_time_passcode(account, actor)

      assert {:error, :invalid_code} =
               verify_one_time_passcode(account.id, actor.id, passcode.id, "wrong")
    end

    test "fails to verify one-time passcode with wrong passcode_id" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      {:ok, passcode} = create_one_time_passcode(account, actor)

      assert {:error, :invalid_code} =
               verify_one_time_passcode(account.id, actor.id, Ecto.UUID.generate(), passcode.code)
    end

    test "fails to verify one-time passcode with wrong actor_id" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      {:ok, passcode} = create_one_time_passcode(account, actor)

      assert {:error, :invalid_code} =
               verify_one_time_passcode(
                 account.id,
                 Ecto.UUID.generate(),
                 passcode.id,
                 passcode.code
               )
    end

    test "one-time passcode can only be used once" do
      account = account_fixture()
      actor = actor_fixture(account: account, allow_email_otp_sign_in: true)

      {:ok, passcode} = create_one_time_passcode(account, actor)

      assert {:ok, _} = verify_one_time_passcode(account.id, actor.id, passcode.id, passcode.code)

      assert {:error, :invalid_code} =
               verify_one_time_passcode(account.id, actor.id, passcode.id, passcode.code)
    end

    test "tracks failed attempts without deleting before the limit" do
      account = account_fixture()
      actor = actor_fixture(account: account, allow_email_otp_sign_in: true)

      {:ok, passcode} = create_one_time_passcode(account, actor)

      for _ <- 1..(Portal.OneTimePasscode.max_attempts() - 1) do
        assert {:error, :invalid_code} =
                 verify_one_time_passcode(account.id, actor.id, passcode.id, "wrong")
      end

      assert {:ok, _} =
               verify_one_time_passcode(account.id, actor.id, passcode.id, passcode.code)
    end

    test "deletes the passcode after the maximum number of failed attempts" do
      account = account_fixture()
      actor = actor_fixture(account: account, allow_email_otp_sign_in: true)

      {:ok, passcode} = create_one_time_passcode(account, actor)

      for _ <- 1..Portal.OneTimePasscode.max_attempts() do
        assert {:error, :invalid_code} =
                 verify_one_time_passcode(account.id, actor.id, passcode.id, "wrong")
      end

      # The passcode is deleted, so even the correct code no longer verifies
      assert {:error, :invalid_code} =
               verify_one_time_passcode(account.id, actor.id, passcode.id, passcode.code)

      refute Repo.get_by(Portal.OneTimePasscode, id: passcode.id)
    end

    test "creating a new passcode deletes existing passcodes for the actor" do
      account = account_fixture()
      actor = actor_fixture(account: account, allow_email_otp_sign_in: true)

      {:ok, passcode1} = create_one_time_passcode(account, actor)
      {:ok, passcode2} = create_one_time_passcode(account, actor)

      # First passcode should no longer be valid
      assert {:error, :invalid_code} =
               verify_one_time_passcode(account.id, actor.id, passcode1.id, passcode1.code)

      # Second passcode should still be valid
      assert {:ok, _} =
               verify_one_time_passcode(account.id, actor.id, passcode2.id, passcode2.code)
    end

    test "creates token with custom nonce" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      auth_provider = auth_provider_fixture(account: account)

      attrs = %{
        account_id: account.id,
        actor_id: actor.id,
        auth_provider_id: auth_provider.id,
        secret_nonce: "my-custom-nonce",
        expires_at: DateTime.add(DateTime.utc_now(), 1, :day)
      }

      assert {:ok, token} = create_interactive_client_token(attrs)
      assert token.secret_hash != nil
      assert token.secret_nonce == "my-custom-nonce"
    end

    test "generates unique secret_salt for each token" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      auth_provider = auth_provider_fixture(account: account)

      base_attrs = %{
        account_id: account.id,
        actor_id: actor.id,
        auth_provider_id: auth_provider.id,
        secret_nonce: "testnonce",
        expires_at: DateTime.add(DateTime.utc_now(), 1, :day)
      }

      {:ok, token1} = create_interactive_client_token(base_attrs)
      {:ok, token2} = create_interactive_client_token(base_attrs)

      assert token1.secret_salt != token2.secret_salt
    end

    test "generates unique secret_hash for same nonce with different salt" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      auth_provider = auth_provider_fixture(account: account)

      attrs = %{
        account_id: account.id,
        actor_id: actor.id,
        auth_provider_id: auth_provider.id,
        secret_nonce: "testnonce",
        expires_at: DateTime.add(DateTime.utc_now(), 1, :day)
      }

      {:ok, token1} = create_interactive_client_token(attrs)
      {:ok, token2} = create_interactive_client_token(attrs)

      # Same nonce but different salts/fragments should produce different hashes
      assert token1.secret_hash != token2.secret_hash
    end

    test "creates a portal session" do
      account = account_fixture()
      actor = admin_actor_fixture(account: account)
      auth_provider = auth_provider_fixture(account: account)
      context = build_context(type: :browser)
      expires_at = DateTime.add(DateTime.utc_now(), 1, :day)

      assert {:ok, session} =
               create_portal_session(actor, auth_provider.id, context, expires_at)

      assert session.id != nil
      assert session.account_id == account.id
      assert session.actor_id == actor.id
      assert session.auth_provider_id == auth_provider.id

      assert [session_log] = Portal.Repo.all(Portal.SessionLog)
      assert session_log.context == :portal
      assert session_log.account_id == account.id
      assert DateTime.diff(DateTime.utc_now(), session_log.timestamp, :second) < 5
      assert session_log.subject["actor_id"] == actor.id
      assert session_log.subject["actor_email"] == actor.email
      assert session_log.subject["auth_provider_id"] == auth_provider.id
    end

    test "rolls back the portal session when the session log write fails" do
      account = account_fixture()
      actor = admin_actor_fixture(account: account)
      auth_provider = auth_provider_fixture(account: account)
      log_id = Portal.Types.LogId.build_session_log()

      log_attrs = %{
        account_id: account.id,
        log_id: log_id,
        timestamp: DateTime.utc_now(),
        context: :portal,
        subject: %{}
      }

      # Pre-seed the log row so the transaction's log insert collides on the
      # (account_id, log_id) primary key and fails.
      Portal.Repo.insert_all(Portal.SessionLog, [log_attrs])

      session = %Portal.PortalSession{
        account_id: account.id,
        actor_id: actor.id,
        auth_provider_id: auth_provider.id,
        user_agent: "test-browser/1.0",
        remote_ip: %Postgrex.INET{address: {100, 64, 0, 1}},
        expires_at: DateTime.add(DateTime.utc_now(), 1, :day)
      }

      assert_raise Postgrex.Error, fn ->
        Authentication.Database.insert_portal_session_with_log(session, log_attrs)
      end

      # Fail closed: the session must not persist without its audit record.
      assert Portal.Repo.all(Portal.PortalSession) == []
      assert [%Portal.SessionLog{log_id: ^log_id}] = Portal.Repo.all(Portal.SessionLog)
    end

    test "creates a portal session for disabled account" do
      account = account_fixture()
      actor = admin_actor_fixture(account: account)
      auth_provider = auth_provider_fixture(account: account)
      context = build_context(type: :browser)
      expires_at = DateTime.add(DateTime.utc_now(), 1, :day)

      account
      |> Ecto.Changeset.change(disabled_at: DateTime.utc_now())
      |> Portal.Repo.update!()

      assert {:ok, session} =
               create_portal_session(actor, auth_provider.id, context, expires_at)

      assert session.id != nil
      assert session.account_id == account.id
    end

    test "raises for account_user actor type when creating portal session" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      auth_provider = auth_provider_fixture(account: account)
      context = build_context(type: :browser)
      expires_at = DateTime.add(DateTime.utc_now(), 1, :day)

      assert_raise FunctionClauseError, fn ->
        create_portal_session(actor, auth_provider.id, context, expires_at)
      end
    end
  end

  describe "use_token/2" do
    test "returns token when valid" do
      token = client_token_fixture()
      encoded = encode_token(token)
      context = build_context(type: :client)

      assert {:ok, used_token} = use_token(encoded, context)
      assert used_token.id == token.id
    end

    test "returns error for invalid token" do
      context = build_context(type: :client)

      assert {:error, :invalid_token} = use_token("invalid.token", context)
    end

    test "returns error for empty string" do
      context = build_context(type: :client)
      assert {:error, :invalid_token} = use_token("", context)
    end

    test "returns error for token without separator" do
      context = build_context(type: :client)
      assert {:error, :invalid_token} = use_token("notokenhere", context)
    end

    test "returns error when token type doesn't match context" do
      encoded = encode_token(client_token_fixture())
      context = build_context(type: :api_client)

      assert {:error, :invalid_token} = use_token(encoded, context)
    end

    test "returns error for expired token" do
      token =
        client_token_fixture(expires_at: DateTime.add(DateTime.utc_now(), -1, :hour))

      encoded = encode_token(token)
      context = build_context(type: :client)

      assert {:error, :invalid_token} = use_token(encoded, context)
    end

    test "returns error when token deleted from database" do
      token = client_token_fixture()
      encoded = encode_token(token)
      Repo.delete!(token)

      context = build_context(type: :client)
      assert {:error, :invalid_token} = use_token(encoded, context)
    end

    test "does not update last_seen fields on client token (recorded on devices)" do
      token = client_token_fixture()
      encoded = encode_token(token)

      context =
        build_context(
          type: :client,
          remote_ip: {10, 0, 0, 1},
          user_agent: "TestAgent/1.0"
        )

      assert {:ok, _used_token} = use_token(encoded, context)

      # Client tokens no longer track last_seen_* — session data is stored on the device
      updated_token = Repo.get_by(ClientToken, id: token.id)
      assert is_nil(updated_token.last_used_device)
    end

    test "can use token multiple times" do
      token = client_token_fixture()
      encoded = encode_token(token)
      context = build_context(type: :client)

      assert {:ok, _} = use_token(encoded, context)
      assert {:ok, _} = use_token(encoded, context)
      assert {:ok, used_token} = use_token(encoded, context)
      assert used_token.id == token.id
    end

    test "works with client token type" do
      token = client_token_fixture()
      encoded = encode_token(token)
      context = build_context(type: :client)

      assert {:ok, used_token} = use_token(encoded, context)
      assert used_token.id == token.id
    end

    test "works with api_client token type" do
      account = account_fixture()
      actor = actor_fixture(account: account, type: :api_client)

      token = api_token_fixture(account: account, actor: actor)
      encoded = encode_api_token(token)

      context = build_context(type: :api_client)

      assert {:ok, used_token} = use_token(encoded, context)
      assert used_token.id == token.id
    end

    test "works with relay token type" do
      token = relay_token_fixture()
      encoded = encode_relay_token(token)

      assert {:ok, verified_token} = verify_relay_token(encoded)
      assert verified_token.id == token.id
    end

    test "works with gateway token type" do
      account = account_fixture()
      site = site_fixture(account: account)
      token = gateway_token_fixture(account: account, site: site)
      encoded = encode_gateway_token(token)

      assert {:ok, verified_token} = verify_gateway_token(encoded)
      assert verified_token.id == token.id
    end

    test "gateway token verification succeeds for disabled account" do
      account = account_fixture()
      site = site_fixture(account: account)
      token = gateway_token_fixture(account: account, site: site)
      encoded = encode_gateway_token(token)

      account
      |> Ecto.Changeset.change(disabled_at: DateTime.utc_now())
      |> Portal.Repo.update!()

      assert {:ok, verified_token} = verify_gateway_token(encoded)
      assert verified_token.id == token.id
    end

    test "returns error when fragment is wrong" do
      encoded = encode_token(client_token_fixture(secret_nonce: "test"))
      context = build_context(type: :client)

      # Corrupt the fragment
      [nonce, _fragment] = String.split(encoded, ".", parts: 2)
      corrupted = nonce <> ".corrupted_fragment"

      assert {:error, :invalid_token} = use_token(corrupted, context)
    end
  end

  describe "encode_fragment!/1" do
    test "encodes a client token starting with dot (client will prepend nonce)" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      auth_provider = auth_provider_fixture(account: account)

      attrs = %{
        account_id: account.id,
        actor_id: actor.id,
        auth_provider_id: auth_provider.id,
        secret_nonce: "testnonce",
        expires_at: DateTime.add(DateTime.utc_now(), 1, :day)
      }

      {:ok, token} = create_interactive_client_token(attrs)
      encoded = encode_fragment!(token)

      # Fragment starts with "." - client will prepend its nonce
      assert String.starts_with?(encoded, ".")
      assert String.length(encoded) > 10
    end

    test "encoded fragment can be verified with use_token when client prepends nonce" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      auth_provider = auth_provider_fixture(account: account)
      nonce = "testnonce"

      attrs = %{
        account_id: account.id,
        actor_id: actor.id,
        auth_provider_id: auth_provider.id,
        secret_nonce: nonce,
        expires_at: DateTime.add(DateTime.utc_now(), 1, :day)
      }

      {:ok, token} = create_interactive_client_token(attrs)
      encoded = encode_fragment!(token)

      # Client prepends the nonce to the fragment
      full_token = nonce <> encoded

      context = build_context(type: :client)
      assert {:ok, used_token} = use_token(full_token, context)
      assert used_token.id == token.id
    end

    test "encodes relay token" do
      {:ok, token} = create_relay_token()

      encoded = encode_fragment!(token)

      # Verify the encoded token can be used for authentication
      assert {:ok, verified_token} = verify_relay_token(encoded)
      assert verified_token.id == token.id
    end

    test "encodes gateway token" do
      account = account_fixture()
      site = site_fixture(account: account)
      subject = admin_subject_fixture(account: account)

      {:ok, token} = create_gateway_token(site, subject)

      encoded = encode_fragment!(token)

      # Verify the encoded token can be used for authentication
      assert {:ok, verified_token} = verify_gateway_token(encoded)
      assert verified_token.id == token.id
    end
  end

  describe "Portal.Sockets.socket_id/1" do
    test "returns socket id for token id" do
      token_id = Ecto.UUID.generate()
      assert Portal.Sockets.socket_id(token_id) == "socket:#{token_id}"
    end

    test "returns consistent socket id for same token id" do
      token_id = Ecto.UUID.generate()
      assert Portal.Sockets.socket_id(token_id) == Portal.Sockets.socket_id(token_id)
    end

    test "returns different socket ids for different token ids" do
      token_id1 = Ecto.UUID.generate()
      token_id2 = Ecto.UUID.generate()
      assert Portal.Sockets.socket_id(token_id1) != Portal.Sockets.socket_id(token_id2)
    end

    test "handles various UUID formats" do
      # Standard UUID
      uuid = "550e8400-e29b-41d4-a716-446655440000"
      assert Portal.Sockets.socket_id(uuid) == "socket:550e8400-e29b-41d4-a716-446655440000"
    end
  end

  describe "build_subject/2" do
    test "builds subject from client token" do
      token = client_token_fixture()
      context = build_context(type: :client)

      assert {:ok, subject} = build_subject(token, context)
      assert subject.credential.type == :client_token
      assert subject.credential.id == token.id
      assert subject.context == context
    end

    test "builds subject from api_client token" do
      account = account_fixture()
      actor = actor_fixture(account: account, type: :api_client)

      token = api_token_fixture(account: account, actor: actor)

      context = build_context(type: :api_client)

      assert {:ok, subject} = build_subject(token, context)
      assert subject.credential.type == :api_token
      assert subject.credential.id == token.id
      assert subject.actor.id == actor.id
    end

    test "returns error when actor is disabled" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      token = client_token_fixture(account: account, actor: actor)

      actor
      |> Ecto.Changeset.change(disabled_at: DateTime.utc_now())
      |> Portal.Repo.update!()

      context = build_context(type: :client)
      assert {:error, :not_found} = build_subject(token, context)
    end

    test "returns error when actor is deleted" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      token = client_token_fixture(account: account, actor: actor)

      Portal.Repo.delete!(actor)

      context = build_context(type: :client)
      assert {:error, :not_found} = build_subject(token, context)
    end

    test "subject contains correct account" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      token = client_token_fixture(account: account, actor: actor)
      context = build_context(type: :client)

      assert {:ok, subject} = build_subject(token, context)
      assert subject.account.id == account.id
    end

    test "subject contains correct actor" do
      account = account_fixture()
      actor = actor_fixture(account: account, type: :account_admin_user)
      token = client_token_fixture(account: account, actor: actor)
      context = build_context(type: :client)

      assert {:ok, subject} = build_subject(token, context)
      assert subject.actor.id == actor.id
      assert subject.actor.type == :account_admin_user
    end

    test "subject contains expires_at from token" do
      expires_at = DateTime.add(DateTime.utc_now(), 1, :day)
      token = client_token_fixture(expires_at: expires_at)
      context = build_context(type: :client)

      assert {:ok, subject} = build_subject(token, context)
      assert subject.expires_at == token.expires_at
    end

    test "subject contains auth_provider_id from token" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      auth_provider = auth_provider_fixture(account: account)

      token = client_token_fixture(account: account, actor: actor, auth_provider: auth_provider)
      context = build_context(type: :client)

      assert {:ok, subject} = build_subject(token, context)
      assert subject.credential.auth_provider_id == auth_provider.id
    end

    test "subject context matches provided context" do
      token = client_token_fixture()

      context =
        build_context(
          type: :client,
          remote_ip: {1, 2, 3, 4},
          user_agent: "CustomAgent/2.0"
        )

      assert {:ok, subject} = build_subject(token, context)
      assert subject.context.remote_ip == {1, 2, 3, 4}
      assert subject.context.user_agent == "CustomAgent/2.0"
    end
  end

  describe "legacy token compatibility" do
    test "gateway tokens work with legacy gateway_group salt" do
      # This tests backward compatibility for tokens created before
      # the rename from gateway_group to gateway
      account = account_fixture()
      site = site_fixture(account: account)

      token = gateway_token_fixture(account: account, site: site)

      # Manually create an encoded token using the legacy salt
      config = Application.fetch_env!(:portal, Portal.Tokens)
      key_base = Keyword.fetch!(config, :key_base)
      legacy_salt = Keyword.fetch!(config, :salt) <> "gateway_group"
      body = {token.account_id, token.id, token.secret_fragment}
      legacy_encoded = "." <> Plug.Crypto.sign(key_base, legacy_salt, body)

      assert {:ok, verified_token} = verify_gateway_token(legacy_encoded)
      assert verified_token.id == token.id
    end

    test "relay tokens work with legacy relay_group salt" do
      # This tests backward compatibility for tokens created before
      # the rename from relay_group to relay
      token = relay_token_fixture()

      # Manually create an encoded token using the legacy salt
      config = Application.fetch_env!(:portal, Portal.Tokens)
      key_base = Keyword.fetch!(config, :key_base)
      legacy_salt = Keyword.fetch!(config, :salt) <> "relay_group"
      body = {nil, token.id, token.secret_fragment}
      legacy_encoded = "." <> Plug.Crypto.sign(key_base, legacy_salt, body)

      assert {:ok, verified_token} = verify_relay_token(legacy_encoded)
      assert verified_token.id == token.id
    end

    test "new gateway tokens still work with current salt" do
      account = account_fixture()
      site = site_fixture(account: account)
      token = gateway_token_fixture(account: account, site: site)
      encoded = encode_gateway_token(token)

      assert {:ok, verified_token} = verify_gateway_token(encoded)
      assert verified_token.id == token.id
    end

    test "new relay tokens still work with current salt" do
      token = relay_token_fixture()
      encoded = encode_relay_token(token)

      assert {:ok, verified_token} = verify_relay_token(encoded)
      assert verified_token.id == token.id
    end
  end
end
