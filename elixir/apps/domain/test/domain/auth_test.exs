defmodule Domain.AuthTest do
  use Domain.DataCase, async: true
  import Domain.Auth
  import Domain.TokenFixtures
  import Domain.SubjectFixtures
  import Domain.AccountFixtures
  import Domain.ActorFixtures
  import Domain.AuthProviderFixtures
  alias Domain.Token

  describe "create_service_account_token/3" do
    test "returns valid client token for a given service account" do
      account = account_fixture()
      service_account = actor_fixture(account: account, type: :service_account)
      admin_subject = subject_fixture(account: account, actor: %{type: :account_admin_user})

      one_day = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)

      assert {:ok, encoded_token} =
               create_service_account_token(
                 service_account,
                 %{"name" => "test-token", "expires_at" => one_day},
                 admin_subject
               )

      context = build_context(type: :client)
      assert {:ok, subject} = authenticate(encoded_token, context)
      assert subject.account.id == account.id
      assert subject.actor.id == service_account.id
      assert subject.context.type == :client

      assert token = Repo.get_by(Token, id: subject.token_id)
      assert token.name == "test-token"
      assert token.type == :client
      assert token.account_id == account.id
      assert token.actor_id == service_account.id
      assert DateTime.truncate(token.expires_at, :second) == one_day
    end

    test "creates token without expiration" do
      account = account_fixture()
      service_account = actor_fixture(account: account, type: :service_account)
      admin_subject = subject_fixture(account: account, actor: %{type: :account_admin_user})

      assert {:ok, encoded_token} =
               create_service_account_token(
                 service_account,
                 %{"name" => "no-expiry-token"},
                 admin_subject
               )

      context = build_context(type: :client)
      assert {:ok, subject} = authenticate(encoded_token, context)

      token = Repo.get_by(Token, id: subject.token_id)
      assert is_nil(token.expires_at)
    end

    test "token can be used multiple times" do
      account = account_fixture()
      service_account = actor_fixture(account: account, type: :service_account)
      admin_subject = subject_fixture(account: account, actor: %{type: :account_admin_user})

      assert {:ok, encoded_token} =
               create_service_account_token(service_account, %{}, admin_subject)

      context = build_context(type: :client)

      # Use token multiple times
      assert {:ok, _} = authenticate(encoded_token, context)
      assert {:ok, _} = authenticate(encoded_token, context)
      assert {:ok, _} = authenticate(encoded_token, context)
    end

    test "raises an error when trying to create a token for a different account" do
      service_account = actor_fixture(type: :service_account)
      admin_subject = subject_fixture(actor: %{type: :account_admin_user})

      assert_raise FunctionClauseError, fn ->
        create_service_account_token(service_account, %{}, admin_subject)
      end
    end

    test "raises an error when trying to create a token not for a service account" do
      account = account_fixture()
      regular_user = actor_fixture(account: account, type: :account_user)
      admin_subject = subject_fixture(account: account, actor: %{type: :account_admin_user})

      assert_raise FunctionClauseError, fn ->
        create_service_account_token(regular_user, %{}, admin_subject)
      end
    end

    test "raises for account_admin_user actor type" do
      account = account_fixture()
      admin_user = actor_fixture(account: account, type: :account_admin_user)
      admin_subject = subject_fixture(account: account, actor: %{type: :account_admin_user})

      assert_raise FunctionClauseError, fn ->
        create_service_account_token(admin_user, %{}, admin_subject)
      end
    end

    test "raises for api_client actor type" do
      account = account_fixture()
      api_client = actor_fixture(account: account, type: :api_client)
      admin_subject = subject_fixture(account: account, actor: %{type: :account_admin_user})

      assert_raise FunctionClauseError, fn ->
        create_service_account_token(api_client, %{}, admin_subject)
      end
    end

    test "creates token with custom name" do
      account = account_fixture()
      service_account = actor_fixture(account: account, type: :service_account)
      admin_subject = subject_fixture(account: account, actor: %{type: :account_admin_user})

      assert {:ok, encoded_token} =
               create_service_account_token(
                 service_account,
                 %{"name" => "my-custom-token-name"},
                 admin_subject
               )

      context = build_context(type: :client)
      assert {:ok, subject} = authenticate(encoded_token, context)

      token = Repo.get_by(Token, id: subject.token_id)
      assert token.name == "my-custom-token-name"
    end
  end

  describe "create_api_client_token/3" do
    test "returns valid api_client token for a given api_client actor" do
      account = account_fixture()
      api_client = actor_fixture(account: account, type: :api_client)
      admin_subject = subject_fixture(account: account, actor: %{type: :account_admin_user})

      one_day = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)

      assert {:ok, encoded_token} =
               create_api_client_token(
                 api_client,
                 %{"name" => "test-token", "expires_at" => one_day},
                 admin_subject
               )

      context = build_context(type: :api_client)
      assert {:ok, subject} = authenticate(encoded_token, context)
      assert subject.account.id == account.id
      assert subject.actor.id == api_client.id
      assert subject.context.type == :api_client

      assert token = Repo.get_by(Token, id: subject.token_id)
      assert token.name == "test-token"
      assert token.type == :api_client
      assert token.account_id == account.id
      assert token.actor_id == api_client.id
      assert DateTime.truncate(token.expires_at, :second) == one_day
    end

    test "creates token without expiration" do
      account = account_fixture()
      api_client = actor_fixture(account: account, type: :api_client)
      admin_subject = subject_fixture(account: account, actor: %{type: :account_admin_user})

      assert {:ok, encoded_token} =
               create_api_client_token(
                 api_client,
                 %{"name" => "no-expiry-token"},
                 admin_subject
               )

      context = build_context(type: :api_client)
      assert {:ok, subject} = authenticate(encoded_token, context)

      token = Repo.get_by(Token, id: subject.token_id)
      assert is_nil(token.expires_at)
    end

    test "token can be used multiple times" do
      account = account_fixture()
      api_client = actor_fixture(account: account, type: :api_client)
      admin_subject = subject_fixture(account: account, actor: %{type: :account_admin_user})

      assert {:ok, encoded_token} =
               create_api_client_token(api_client, %{}, admin_subject)

      context = build_context(type: :api_client)

      # Use token multiple times
      assert {:ok, _} = authenticate(encoded_token, context)
      assert {:ok, _} = authenticate(encoded_token, context)
      assert {:ok, _} = authenticate(encoded_token, context)
    end

    test "raises an error when trying to create a token for a different account" do
      api_client = actor_fixture(type: :api_client)
      admin_subject = subject_fixture(actor: %{type: :account_admin_user})

      assert_raise FunctionClauseError, fn ->
        create_api_client_token(api_client, %{}, admin_subject)
      end
    end

    test "raises an error when trying to create a token not for an api_client" do
      account = account_fixture()
      regular_user = actor_fixture(account: account, type: :account_user)
      admin_subject = subject_fixture(account: account, actor: %{type: :account_admin_user})

      assert_raise FunctionClauseError, fn ->
        create_api_client_token(regular_user, %{}, admin_subject)
      end
    end

    test "raises for service_account actor type" do
      account = account_fixture()
      service_account = actor_fixture(account: account, type: :service_account)
      admin_subject = subject_fixture(account: account, actor: %{type: :account_admin_user})

      assert_raise FunctionClauseError, fn ->
        create_api_client_token(service_account, %{}, admin_subject)
      end
    end

    test "raises for account_admin_user actor type" do
      account = account_fixture()
      admin_user = actor_fixture(account: account, type: :account_admin_user)
      admin_subject = subject_fixture(account: account, actor: %{type: :account_admin_user})

      assert_raise FunctionClauseError, fn ->
        create_api_client_token(admin_user, %{}, admin_subject)
      end
    end
  end

  describe "authenticate/2" do
    test "returns error when token is invalid" do
      context = build_context(type: :browser)

      assert authenticate("invalid.token", context) == {:error, :invalid_token}
      assert authenticate("foo", context) == {:error, :invalid_token}
      assert authenticate(".invalid", context) == {:error, :invalid_token}
    end

    test "returns error for empty token" do
      context = build_context(type: :browser)
      assert authenticate("", context) == {:error, :invalid_token}
    end

    test "returns error for token with only nonce" do
      context = build_context(type: :browser)
      assert authenticate("justnonce.", context) == {:error, :invalid_token}
    end

    test "returns error for token with only fragment" do
      context = build_context(type: :browser)
      assert authenticate(".justfragment", context) == {:error, :invalid_token}
    end

    test "returns error when token is issued for a different context type" do
      browser_encoded = encode_token(browser_token_fixture())
      client_encoded = encode_token(client_token_fixture())

      browser_context = build_context(type: :browser)
      client_context = build_context(type: :client)

      # Browser token used with client context
      assert authenticate(browser_encoded, client_context) == {:error, :invalid_token}
      # Client token used with browser context
      assert authenticate(client_encoded, browser_context) == {:error, :invalid_token}
    end

    test "returns error when browser token used with api_client context" do
      encoded = encode_token(browser_token_fixture())
      context = build_context(type: :api_client)
      assert authenticate(encoded, context) == {:error, :invalid_token}
    end

    test "returns error when client token used with api_client context" do
      encoded = encode_token(client_token_fixture())
      context = build_context(type: :api_client)
      assert authenticate(encoded, context) == {:error, :invalid_token}
    end

    test "returns error when api_client token used with browser context" do
      encoded = encode_token(api_client_token_fixture())
      context = build_context(type: :browser)
      assert authenticate(encoded, context) == {:error, :invalid_token}
    end

    test "returns error when nonce is invalid" do
      encoded = encode_token(browser_token_fixture(secret_nonce: "correct"))
      context = build_context(type: :browser)

      # Replace correct nonce with wrong one
      wrong_nonce_token = "wrong" <> String.slice(encoded, 7..-1//1)
      assert authenticate(wrong_nonce_token, context) == {:error, :invalid_token}
    end

    test "returns error when nonce is empty but expected non-empty" do
      encoded = encode_token(browser_token_fixture(secret_nonce: "nonempty"))
      context = build_context(type: :browser)

      # Remove the nonce entirely
      [_nonce, fragment] = String.split(encoded, ".", parts: 2)
      empty_nonce_token = "." <> fragment
      assert authenticate(empty_nonce_token, context) == {:error, :invalid_token}
    end

    test "returns subject for browser token" do
      account = account_fixture()
      actor = actor_fixture(account: account, type: :account_admin_user)

      token = browser_token_fixture(account: account, actor: actor)
      encoded = encode_token(token)

      context = build_context(type: :browser)

      assert {:ok, subject} = authenticate(encoded, context)
      assert subject.actor.id == actor.id
      assert subject.account.id == account.id
      assert subject.token_id == token.id
      assert subject.context.remote_ip == context.remote_ip
      assert subject.context.user_agent == context.user_agent
      assert subject.expires_at == token.expires_at
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
      assert subject.token_id == token.id
      assert subject.expires_at == token.expires_at
    end

    test "returns subject for api_client token" do
      account = account_fixture()
      actor = actor_fixture(account: account, type: :api_client)

      token = api_client_token_fixture(account: account, actor: actor)
      encoded = encode_token(token)

      context = build_context(type: :api_client)

      assert {:ok, subject} = authenticate(encoded, context)
      assert subject.actor.id == actor.id
      assert subject.account.id == account.id
      assert subject.token_id == token.id
    end

    test "returns subject for service account token" do
      account = account_fixture()
      service_account = actor_fixture(account: account, type: :service_account)
      admin_subject = subject_fixture(account: account, actor: %{type: :account_admin_user})

      assert {:ok, encoded_token} =
               create_service_account_token(service_account, %{}, admin_subject)

      context = build_context(type: :client)
      assert {:ok, subject} = authenticate(encoded_token, context)
      assert subject.actor.id == service_account.id
      assert subject.account.id == account.id
    end

    test "updates last seen fields for token on success" do
      encoded = encode_token(browser_token_fixture())

      context =
        build_context(
          type: :browser,
          remote_ip: {192, 168, 1, 100},
          remote_ip_location_region: "UA",
          remote_ip_location_city: "Kyiv",
          remote_ip_location_lat: 50.45,
          remote_ip_location_lon: 30.52,
          user_agent: "Test/1.0"
        )

      assert {:ok, subject} = authenticate(encoded, context)

      updated_token = Repo.get_by(Token, id: subject.token_id)
      assert updated_token.last_seen_remote_ip.address == context.remote_ip

      assert updated_token.last_seen_remote_ip_location_region ==
               context.remote_ip_location_region

      assert updated_token.last_seen_remote_ip_location_city == context.remote_ip_location_city
      assert updated_token.last_seen_remote_ip_location_lat == context.remote_ip_location_lat
      assert updated_token.last_seen_remote_ip_location_lon == context.remote_ip_location_lon
      assert updated_token.last_seen_user_agent == context.user_agent
    end

    test "updates last_seen_at timestamp on each use" do
      token = browser_token_fixture()
      encoded = encode_token(token)
      context = build_context(type: :browser)

      # First use
      assert {:ok, _} = authenticate(encoded, context)
      token_after_first = Repo.get_by(Token, id: token.id)

      # Small delay to ensure timestamp difference
      Process.sleep(10)

      # Second use
      assert {:ok, _} = authenticate(encoded, context)
      token_after_second = Repo.get_by(Token, id: token.id)

      assert DateTime.compare(token_after_second.last_seen_at, token_after_first.last_seen_at) in [
               :gt,
               :eq
             ]
    end

    test "returns error when actor is deleted" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      encoded = encode_token(browser_token_fixture(account: account, actor: actor))

      Domain.Repo.delete!(actor)

      context = build_context(type: :browser)
      assert authenticate(encoded, context) == {:error, :invalid_token}
    end

    test "returns error when actor is disabled" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      encoded = encode_token(browser_token_fixture(account: account, actor: actor))

      actor
      |> Ecto.Changeset.change(disabled_at: DateTime.utc_now())
      |> Domain.Repo.update!()

      context = build_context(type: :browser)
      assert authenticate(encoded, context) == {:error, :invalid_token}
    end

    test "returns error when token is expired" do
      token =
        token_fixture(
          type: :browser,
          expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        )

      encoded = encode_token(token)
      context = build_context(type: :browser)
      assert authenticate(encoded, context) == {:error, :invalid_token}
    end

    test "returns error when token expired just now" do
      token =
        token_fixture(
          type: :browser,
          expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
        )

      encoded = encode_token(token)
      context = build_context(type: :browser)
      assert authenticate(encoded, context) == {:error, :invalid_token}
    end

    test "succeeds when token expires in the future" do
      token =
        token_fixture(
          type: :browser,
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        )

      encoded = encode_token(token)
      context = build_context(type: :browser)
      assert {:ok, _subject} = authenticate(encoded, context)
    end

    test "returns error when token does not exist in database" do
      # Create and then delete the token
      token = browser_token_fixture()
      encoded = encode_token(token)
      Repo.delete!(token)

      context = build_context(type: :browser)
      assert authenticate(encoded, context) == {:error, :invalid_token}
    end

    test "returns error when fragment is tampered with" do
      encoded = encode_token(browser_token_fixture())
      context = build_context(type: :browser)

      # Tamper with the fragment part
      [nonce, fragment] = String.split(encoded, ".", parts: 2)
      tampered = nonce <> "." <> fragment <> "tampered"
      assert authenticate(tampered, context) == {:error, :invalid_token}
    end

    test "handles IPv6 addresses in context" do
      encoded = encode_token(browser_token_fixture())

      context =
        build_context(
          type: :browser,
          remote_ip: {0, 0, 0, 0, 0, 0, 0, 1}
        )

      assert {:ok, subject} = authenticate(encoded, context)
      updated_token = Repo.get_by(Token, id: subject.token_id)
      assert updated_token.last_seen_remote_ip.address == {0, 0, 0, 0, 0, 0, 0, 1}
    end

    test "handles various user agent strings" do
      encoded = encode_token(browser_token_fixture())

      # DB has 255 char limit for user_agent
      user_agent = String.duplicate("M", 255)

      context =
        build_context(
          type: :browser,
          user_agent: user_agent
        )

      assert {:ok, subject} = authenticate(encoded, context)
      updated_token = Repo.get_by(Token, id: subject.token_id)
      assert updated_token.last_seen_user_agent == user_agent
    end

    test "subject contains auth_provider_id when present on token" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      auth_provider = auth_provider_fixture(account: account)

      token = client_token_fixture(account: account, actor: actor, auth_provider: auth_provider)
      encoded = encode_token(token)
      context = build_context(type: :client)

      assert {:ok, subject} = authenticate(encoded, context)
      assert subject.auth_provider_id == auth_provider.id
    end
  end

  describe "create_token/1" do
    test "creates a browser token with required attributes" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      attrs = %{
        type: :browser,
        account_id: account.id,
        actor_id: actor.id,
        secret_fragment: Domain.Crypto.random_token(32, encoder: :hex32),
        expires_at: DateTime.add(DateTime.utc_now(), 1, :day)
      }

      assert {:ok, token} = create_token(attrs)
      assert token.type == :browser
      assert token.account_id == account.id
      assert token.actor_id == actor.id
      assert token.secret_salt != nil
      assert token.secret_hash != nil
    end

    test "fails to create browser token without expires_at" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      attrs = %{
        type: :browser,
        account_id: account.id,
        actor_id: actor.id,
        secret_fragment: Domain.Crypto.random_token(32, encoder: :hex32)
      }

      assert {:error, changeset} = create_token(attrs)
      assert "can't be blank" in errors_on(changeset).expires_at
    end

    test "fails to create browser token without actor_id" do
      account = account_fixture()

      attrs = %{
        type: :browser,
        account_id: account.id,
        secret_fragment: Domain.Crypto.random_token(32, encoder: :hex32),
        expires_at: DateTime.add(DateTime.utc_now(), 1, :day)
      }

      assert {:error, changeset} = create_token(attrs)
      assert "can't be blank" in errors_on(changeset).actor_id
    end

    test "fails to create browser token with past expires_at" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      attrs = %{
        type: :browser,
        account_id: account.id,
        actor_id: actor.id,
        secret_fragment: Domain.Crypto.random_token(32, encoder: :hex32),
        expires_at: DateTime.add(DateTime.utc_now(), -1, :day)
      }

      assert {:error, changeset} = create_token(attrs)
      assert errors_on(changeset).expires_at != []
    end

    test "creates a client token" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      attrs = %{
        type: :client,
        account_id: account.id,
        actor_id: actor.id,
        secret_fragment: Domain.Crypto.random_token(32, encoder: :hex32),
        expires_at: DateTime.add(DateTime.utc_now(), 30, :day)
      }

      assert {:ok, token} = create_token(attrs)
      assert token.type == :client
    end

    test "creates a client token without expires_at" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      attrs = %{
        type: :client,
        account_id: account.id,
        actor_id: actor.id,
        secret_fragment: Domain.Crypto.random_token(32, encoder: :hex32)
      }

      assert {:ok, token} = create_token(attrs)
      assert token.type == :client
      assert is_nil(token.expires_at)
    end

    test "fails to create client token without actor_id" do
      account = account_fixture()

      attrs = %{
        type: :client,
        account_id: account.id,
        secret_fragment: Domain.Crypto.random_token(32, encoder: :hex32)
      }

      assert {:error, changeset} = create_token(attrs)
      assert "can't be blank" in errors_on(changeset).actor_id
    end

    test "creates an api_client token" do
      account = account_fixture()
      actor = actor_fixture(account: account, type: :api_client)

      attrs = %{
        type: :api_client,
        account_id: account.id,
        actor_id: actor.id,
        secret_fragment: Domain.Crypto.random_token(32, encoder: :hex32)
      }

      assert {:ok, token} = create_token(attrs)
      assert token.type == :api_client
    end

    test "fails to create api_client token without actor_id" do
      account = account_fixture()

      attrs = %{
        type: :api_client,
        account_id: account.id,
        secret_fragment: Domain.Crypto.random_token(32, encoder: :hex32)
      }

      assert {:error, changeset} = create_token(attrs)
      assert "can't be blank" in errors_on(changeset).actor_id
    end

    test "creates a relay token" do
      assert {:ok, token} = create_relay_token()
      assert token.id != nil
      assert token.secret_fragment != nil
      assert token.secret_nonce != nil
      assert token.secret_hash != nil
      assert token.secret_salt != nil
    end

    test "creates a gateway token" do
      account = account_fixture()
      site = Domain.SiteFixtures.site_fixture(account: account)
      subject = admin_subject_fixture(account: account)

      assert {:ok, token} = create_gateway_token(site, subject)
      assert token.id != nil
      assert token.account_id == account.id
      assert token.site_id == site.id
      assert token.secret_fragment != nil
      assert token.secret_nonce != nil
      assert token.secret_hash != nil
      assert token.secret_salt != nil
    end

    test "non-admin user cannot create gateway token" do
      account = account_fixture()
      site = Domain.SiteFixtures.site_fixture(account: account)
      subject = subject_fixture(account: account, actor: %{type: :account_user})

      assert {:error, :unauthorized} = create_gateway_token(site, subject)
    end

    test "creates a one-time passcode" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      assert {:ok, passcode} = create_one_time_passcode(account, actor)
      assert passcode.id != nil
      assert passcode.account_id == account.id
      assert passcode.actor_id == actor.id
      assert passcode.code != nil
      assert String.length(passcode.code) == 5
      assert passcode.code_hash != nil
      assert passcode.expires_at != nil
    end

    test "verifies a valid one-time passcode" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      {:ok, passcode} = create_one_time_passcode(account, actor)

      assert {:ok, verified_passcode} =
               verify_one_time_passcode(account.id, passcode.id, passcode.code)

      assert verified_passcode.id == passcode.id
      assert verified_passcode.actor_id == actor.id
    end

    test "fails to verify one-time passcode with wrong code" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      {:ok, passcode} = create_one_time_passcode(account, actor)

      assert {:error, :invalid_code} =
               verify_one_time_passcode(account.id, passcode.id, "wrong")
    end

    test "fails to verify one-time passcode with wrong passcode_id" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      {:ok, passcode} = create_one_time_passcode(account, actor)

      assert {:error, :invalid_code} =
               verify_one_time_passcode(account.id, Ecto.UUID.generate(), passcode.code)
    end

    test "one-time passcode can only be used once" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      {:ok, passcode} = create_one_time_passcode(account, actor)

      assert {:ok, _} = verify_one_time_passcode(account.id, passcode.id, passcode.code)

      assert {:error, :invalid_code} =
               verify_one_time_passcode(account.id, passcode.id, passcode.code)
    end

    test "creating a new passcode deletes existing passcodes for the actor" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      {:ok, passcode1} = create_one_time_passcode(account, actor)
      {:ok, passcode2} = create_one_time_passcode(account, actor)

      # First passcode should no longer be valid
      assert {:error, :invalid_code} =
               verify_one_time_passcode(account.id, passcode1.id, passcode1.code)

      # Second passcode should still be valid
      assert {:ok, _} = verify_one_time_passcode(account.id, passcode2.id, passcode2.code)
    end

    test "fails to create token without type" do
      account = account_fixture()

      attrs = %{
        account_id: account.id,
        secret_fragment: Domain.Crypto.random_token(32, encoder: :hex32)
      }

      assert {:error, changeset} = create_token(attrs)
      assert "can't be blank" in errors_on(changeset).type
    end

    test "fails to create token without secret_fragment" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      attrs = %{
        type: :browser,
        account_id: account.id,
        actor_id: actor.id,
        expires_at: DateTime.add(DateTime.utc_now(), 1, :day)
      }

      assert {:error, changeset} = create_token(attrs)
      assert "can't be blank" in errors_on(changeset).secret_fragment
    end

    test "creates token with custom nonce" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      attrs = %{
        type: :client,
        account_id: account.id,
        actor_id: actor.id,
        secret_fragment: Domain.Crypto.random_token(32, encoder: :hex32),
        secret_nonce: "my-custom-nonce"
      }

      assert {:ok, token} = create_token(attrs)
      # Nonce is used in hash computation but not stored
      assert token.secret_hash != nil
    end

    test "fails when nonce contains period" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      attrs = %{
        type: :client,
        account_id: account.id,
        actor_id: actor.id,
        secret_fragment: Domain.Crypto.random_token(32, encoder: :hex32),
        secret_nonce: "invalid.nonce"
      }

      assert {:error, changeset} = create_token(attrs)
      assert errors_on(changeset).secret_nonce != []
    end

    test "fails when nonce is too long" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      attrs = %{
        type: :client,
        account_id: account.id,
        actor_id: actor.id,
        secret_fragment: Domain.Crypto.random_token(32, encoder: :hex32),
        secret_nonce: String.duplicate("a", 129)
      }

      assert {:error, changeset} = create_token(attrs)
      assert errors_on(changeset).secret_nonce != []
    end

    test "allows nonce at maximum length" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      attrs = %{
        type: :client,
        account_id: account.id,
        actor_id: actor.id,
        secret_fragment: Domain.Crypto.random_token(32, encoder: :hex32),
        secret_nonce: String.duplicate("a", 128)
      }

      assert {:ok, _token} = create_token(attrs)
    end

    test "creates token with name" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      attrs = %{
        type: :client,
        account_id: account.id,
        actor_id: actor.id,
        secret_fragment: Domain.Crypto.random_token(32, encoder: :hex32),
        name: "My Token"
      }

      assert {:ok, token} = create_token(attrs)
      assert token.name == "My Token"
    end

    test "generates unique secret_salt for each token" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      base_attrs = %{
        type: :client,
        account_id: account.id,
        actor_id: actor.id,
        secret_fragment: Domain.Crypto.random_token(32, encoder: :hex32)
      }

      {:ok, token1} = create_token(base_attrs)
      {:ok, token2} = create_token(base_attrs)

      assert token1.secret_salt != token2.secret_salt
    end

    test "generates unique secret_hash for same fragment with different salt" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      fragment = Domain.Crypto.random_token(32, encoder: :hex32)

      attrs = %{
        type: :client,
        account_id: account.id,
        actor_id: actor.id,
        secret_fragment: fragment
      }

      {:ok, token1} = create_token(attrs)
      {:ok, token2} = create_token(attrs)

      # Same fragment but different salts should produce different hashes
      assert token1.secret_hash != token2.secret_hash
    end
  end

  describe "create_token/2" do
    test "creates a token with subject's account_id" do
      account = account_fixture()
      subject = subject_fixture(account: account)

      attrs = %{
        type: :browser,
        actor_id: subject.actor.id,
        secret_fragment: Domain.Crypto.random_token(32, encoder: :hex32),
        expires_at: DateTime.add(DateTime.utc_now(), 1, :day)
      }

      assert {:ok, token} = create_token(attrs, subject)
      assert token.type == :browser
      assert token.account_id == account.id
      assert token.actor_id == subject.actor.id
    end

    test "overrides account_id from attrs with subject's account_id" do
      account = account_fixture()
      other_account = account_fixture()
      subject = subject_fixture(account: account)

      attrs = %{
        type: :browser,
        account_id: other_account.id,
        actor_id: subject.actor.id,
        secret_fragment: Domain.Crypto.random_token(32, encoder: :hex32),
        expires_at: DateTime.add(DateTime.utc_now(), 1, :day)
      }

      assert {:ok, token} = create_token(attrs, subject)
      # Subject's account_id is used, not the one from attrs
      assert token.account_id == account.id
    end

    test "creates client token with subject" do
      account = account_fixture()
      subject = subject_fixture(account: account)
      service_account = actor_fixture(account: account, type: :service_account)

      attrs = %{
        type: :client,
        actor_id: service_account.id,
        secret_fragment: Domain.Crypto.random_token(32, encoder: :hex32)
      }

      assert {:ok, token} = create_token(attrs, subject)
      assert token.type == :client
      assert token.account_id == account.id
      assert token.actor_id == service_account.id
    end

    test "creates api_client token with subject" do
      account = account_fixture()
      subject = subject_fixture(account: account)
      api_client = actor_fixture(account: account, type: :api_client)

      attrs = %{
        type: :api_client,
        actor_id: api_client.id,
        secret_fragment: Domain.Crypto.random_token(32, encoder: :hex32)
      }

      assert {:ok, token} = create_token(attrs, subject)
      assert token.type == :api_client
      assert token.account_id == account.id
    end
  end

  describe "use_token/2" do
    test "returns token when valid" do
      token = browser_token_fixture()
      encoded = encode_token(token)
      context = build_context(type: :browser)

      assert {:ok, used_token} = use_token(encoded, context)
      assert used_token.id == token.id
    end

    test "returns error for invalid token" do
      context = build_context(type: :browser)

      assert {:error, :invalid_token} = use_token("invalid.token", context)
    end

    test "returns error for empty string" do
      context = build_context(type: :browser)
      assert {:error, :invalid_token} = use_token("", context)
    end

    test "returns error for token without separator" do
      context = build_context(type: :browser)
      assert {:error, :invalid_token} = use_token("notokenhere", context)
    end

    test "returns error when token type doesn't match context" do
      encoded = encode_token(browser_token_fixture())
      context = build_context(type: :client)

      assert {:error, :invalid_token} = use_token(encoded, context)
    end

    test "returns error for expired token" do
      token =
        token_fixture(
          type: :browser,
          expires_at: DateTime.add(DateTime.utc_now(), -1, :hour)
        )

      encoded = encode_token(token)
      context = build_context(type: :browser)

      assert {:error, :invalid_token} = use_token(encoded, context)
    end

    test "returns error when token deleted from database" do
      token = browser_token_fixture()
      encoded = encode_token(token)
      Repo.delete!(token)

      context = build_context(type: :browser)
      assert {:error, :invalid_token} = use_token(encoded, context)
    end

    test "updates last_seen fields on token" do
      token = browser_token_fixture()
      encoded = encode_token(token)

      context =
        build_context(
          type: :browser,
          remote_ip: {10, 0, 0, 1},
          user_agent: "TestAgent/1.0"
        )

      assert {:ok, _used_token} = use_token(encoded, context)

      updated_token = Repo.get_by(Token, id: token.id)
      assert updated_token.last_seen_remote_ip.address == {10, 0, 0, 1}
      assert updated_token.last_seen_user_agent == "TestAgent/1.0"
    end

    test "updates all location fields" do
      token = browser_token_fixture()
      encoded = encode_token(token)

      context =
        build_context(
          type: :browser,
          remote_ip: {192, 168, 1, 1},
          remote_ip_location_region: "US",
          remote_ip_location_city: "New York",
          remote_ip_location_lat: 40.7128,
          remote_ip_location_lon: -74.0060,
          user_agent: "Test/1.0"
        )

      assert {:ok, _} = use_token(encoded, context)

      updated_token = Repo.get_by(Token, id: token.id)
      assert updated_token.last_seen_remote_ip_location_region == "US"
      assert updated_token.last_seen_remote_ip_location_city == "New York"
      assert updated_token.last_seen_remote_ip_location_lat == 40.7128
      assert updated_token.last_seen_remote_ip_location_lon == -74.0060
    end

    test "can use token multiple times" do
      token = browser_token_fixture()
      encoded = encode_token(token)
      context = build_context(type: :browser)

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

      token = api_client_token_fixture(account: account, actor: actor)
      encoded = encode_token(token)

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
      site = Domain.SiteFixtures.site_fixture(account: account)
      token = gateway_token_fixture(account: account, site: site)
      encoded = encode_gateway_token(token)

      assert {:ok, verified_token} = verify_gateway_token(encoded)
      assert verified_token.id == token.id
    end

    test "returns error when fragment is wrong" do
      encoded = encode_token(browser_token_fixture(secret_nonce: "test"))
      context = build_context(type: :browser)

      # Corrupt the fragment
      [nonce, _fragment] = String.split(encoded, ".", parts: 2)
      corrupted = nonce <> ".corrupted_fragment"

      assert {:error, :invalid_token} = use_token(corrupted, context)
    end
  end

  describe "encode_fragment!/1" do
    test "encodes a token with secret_fragment" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      attrs = %{
        type: :browser,
        account_id: account.id,
        actor_id: actor.id,
        secret_fragment: Domain.Crypto.random_token(32, encoder: :hex32),
        expires_at: DateTime.add(DateTime.utc_now(), 1, :day)
      }

      {:ok, token} = create_token(attrs)

      # Put the secret_fragment back on the token for encoding
      token = %{token | secret_fragment: attrs.secret_fragment}
      encoded = encode_fragment!(token)

      assert String.starts_with?(encoded, ".")
      assert String.length(encoded) > 10
    end

    test "encoded fragment can be verified with use_token" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      fragment = Domain.Crypto.random_token(32, encoder: :hex32)

      attrs = %{
        type: :browser,
        account_id: account.id,
        actor_id: actor.id,
        secret_fragment: fragment,
        secret_nonce: "testnonce",
        expires_at: DateTime.add(DateTime.utc_now(), 1, :day)
      }

      {:ok, token} = create_token(attrs)
      token = %{token | secret_fragment: fragment}
      encoded_fragment = encode_fragment!(token)

      # Prepend nonce to make full token
      full_token = "testnonce" <> encoded_fragment

      context = build_context(type: :browser)
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
      site = Domain.SiteFixtures.site_fixture(account: account)
      subject = admin_subject_fixture(account: account)

      {:ok, token} = create_gateway_token(site, subject)

      encoded = encode_fragment!(token)

      # Verify the encoded token can be used for authentication
      assert {:ok, verified_token} = verify_gateway_token(encoded)
      assert verified_token.id == token.id
    end
  end

  describe "socket_id/1" do
    test "returns socket id for token id" do
      token_id = Ecto.UUID.generate()
      assert socket_id(token_id) == "tokens:#{token_id}"
    end

    test "returns consistent socket id for same token id" do
      token_id = Ecto.UUID.generate()
      assert socket_id(token_id) == socket_id(token_id)
    end

    test "returns different socket ids for different token ids" do
      token_id1 = Ecto.UUID.generate()
      token_id2 = Ecto.UUID.generate()
      assert socket_id(token_id1) != socket_id(token_id2)
    end

    test "handles various UUID formats" do
      # Standard UUID
      uuid = "550e8400-e29b-41d4-a716-446655440000"
      assert socket_id(uuid) == "tokens:550e8400-e29b-41d4-a716-446655440000"
    end
  end

  describe "build_subject/2" do
    test "builds subject from browser token" do
      token = browser_token_fixture()
      context = build_context(type: :browser)

      assert {:ok, subject} = build_subject(token, context)
      assert subject.token_id == token.id
      assert subject.context == context
    end

    test "builds subject from client token" do
      token = client_token_fixture()
      context = build_context(type: :client)

      assert {:ok, subject} = build_subject(token, context)
      assert subject.token_id == token.id
    end

    test "builds subject from api_client token" do
      account = account_fixture()
      actor = actor_fixture(account: account, type: :api_client)

      token = api_client_token_fixture(account: account, actor: actor)

      context = build_context(type: :api_client)

      assert {:ok, subject} = build_subject(token, context)
      assert subject.token_id == token.id
      assert subject.actor.id == actor.id
    end

    test "returns error when actor is disabled" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      token = browser_token_fixture(account: account, actor: actor)

      actor
      |> Ecto.Changeset.change(disabled_at: DateTime.utc_now())
      |> Domain.Repo.update!()

      context = build_context(type: :browser)
      assert {:error, :not_found} = build_subject(token, context)
    end

    test "returns error when actor is deleted" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      token = browser_token_fixture(account: account, actor: actor)

      Domain.Repo.delete!(actor)

      context = build_context(type: :browser)
      assert {:error, :not_found} = build_subject(token, context)
    end

    test "subject contains correct account" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      token = browser_token_fixture(account: account, actor: actor)
      context = build_context(type: :browser)

      assert {:ok, subject} = build_subject(token, context)
      assert subject.account.id == account.id
    end

    test "subject contains correct actor" do
      account = account_fixture()
      actor = actor_fixture(account: account, type: :account_admin_user)
      token = browser_token_fixture(account: account, actor: actor)
      context = build_context(type: :browser)

      assert {:ok, subject} = build_subject(token, context)
      assert subject.actor.id == actor.id
      assert subject.actor.type == :account_admin_user
    end

    test "subject contains expires_at from token" do
      expires_at = DateTime.add(DateTime.utc_now(), 1, :day)
      token = browser_token_fixture(expires_at: expires_at)
      context = build_context(type: :browser)

      assert {:ok, subject} = build_subject(token, context)
      assert subject.expires_at == token.expires_at
    end

    test "subject contains nil expires_at when token has no expiration" do
      token = client_token_fixture(expires_at: nil)
      context = build_context(type: :client)

      assert {:ok, subject} = build_subject(token, context)
      assert is_nil(subject.expires_at)
    end

    test "subject contains auth_provider_id from token" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      auth_provider = auth_provider_fixture(account: account)

      token = client_token_fixture(account: account, actor: actor, auth_provider: auth_provider)
      context = build_context(type: :client)

      assert {:ok, subject} = build_subject(token, context)
      assert subject.auth_provider_id == auth_provider.id
    end

    test "subject context matches provided context" do
      token = browser_token_fixture()

      context =
        build_context(
          type: :browser,
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
      site = Domain.SiteFixtures.site_fixture(account: account)

      token = gateway_token_fixture(account: account, site: site)

      # Manually create an encoded token using the legacy salt
      config = Application.fetch_env!(:domain, Domain.Tokens)
      key_base = Keyword.fetch!(config, :key_base)
      legacy_salt = Keyword.fetch!(config, :salt) <> "gateway_group"
      body = {token.account_id, token.id, token.secret_fragment}
      legacy_encoded = token.secret_nonce <> "." <> Plug.Crypto.sign(key_base, legacy_salt, body)

      assert {:ok, verified_token} = verify_gateway_token(legacy_encoded)
      assert verified_token.id == token.id
    end

    test "relay tokens work with legacy relay_group salt" do
      # This tests backward compatibility for tokens created before
      # the rename from relay_group to relay
      token = relay_token_fixture()

      # Manually create an encoded token using the legacy salt
      config = Application.fetch_env!(:domain, Domain.Tokens)
      key_base = Keyword.fetch!(config, :key_base)
      legacy_salt = Keyword.fetch!(config, :salt) <> "relay_group"
      body = {nil, token.id, token.secret_fragment}
      legacy_encoded = token.secret_nonce <> "." <> Plug.Crypto.sign(key_base, legacy_salt, body)

      assert {:ok, verified_token} = verify_relay_token(legacy_encoded)
      assert verified_token.id == token.id
    end

    test "new gateway tokens still work with current salt" do
      account = account_fixture()
      site = Domain.SiteFixtures.site_fixture(account: account)
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
