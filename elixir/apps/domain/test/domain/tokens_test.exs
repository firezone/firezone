defmodule Domain.TokensTest do
  use Domain.DataCase, async: true
  import Domain.Tokens
  alias Domain.Tokens

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    subject = Fixtures.Auth.create_subject(account: account, actor: actor, identity: identity)

    %{
      account: account,
      actor: actor,
      identity: identity,
      subject: subject
    }
  end

  describe "fetch_token_by_id/3" do
    test "returns error when subject does not have required permissions", %{
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert fetch_token_by_id(Ecto.UUID.generate(), subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [
                   {:one_of,
                    [
                      Tokens.Authorizer.manage_tokens_permission(),
                      Tokens.Authorizer.manage_own_tokens_permission()
                    ]}
                 ]}}
    end

    test "returns error when token is not found", %{subject: subject} do
      assert fetch_token_by_id(Ecto.UUID.generate(), subject) == {:error, :not_found}
      assert fetch_token_by_id("foo", subject) == {:error, :not_found}
    end

    test "returns token for admin user", %{account: account, subject: subject} do
      token = Fixtures.Tokens.create_token(account: account)
      assert {:ok, _token} = fetch_token_by_id(token.id, subject)
    end

    test "does not return other user tokens for non-admin users", %{account: account} do
      actor = Fixtures.Actors.create_actor(type: :account_user, account: account)
      subject = Fixtures.Auth.create_subject(account: account, actor: actor)

      token = Fixtures.Tokens.create_token(account: account)
      assert fetch_token_by_id(token.id, subject) == {:error, :not_found}
    end
  end

  describe "list_subject_tokens/2" do
    test "returns current subject's tokens", %{
      account: account,
      identity: identity,
      subject: subject
    } do
      token = Fixtures.Tokens.create_token(account: account, identity: identity)
      Fixtures.Tokens.create_token(account: account)
      Fixtures.Tokens.create_token()

      assert {:ok, tokens, _metadata} = list_subject_tokens(subject)
      token_ids = Enum.map(tokens, & &1.id)
      assert token.id in token_ids
      assert subject.token_id in token_ids
      assert length(tokens) == 2
    end

    test "returns error when subject does not have required permissions", %{
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert list_subject_tokens(subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Tokens.Authorizer.manage_own_tokens_permission()]}}
    end
  end

  describe "list_tokens_for/3" do
    test "returns tokens of a given actor", %{
      account: account,
      subject: subject
    } do
      actor = Fixtures.Actors.create_actor(account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      token = Fixtures.Tokens.create_token(account: account, identity: identity)

      Fixtures.Tokens.create_token(account: account)
      Fixtures.Tokens.create_token()

      assert {:ok, [fetched_token], _metadata} = list_tokens_for(actor, subject)
      assert fetched_token.id == token.id
    end

    test "returns error when subject does not have required permissions", %{
      actor: actor,
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert list_tokens_for(actor, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Tokens.Authorizer.manage_tokens_permission()]}}
    end
  end

  describe "create_token/2" do
    test "returns errors on missing required attrs" do
      assert {:error, changeset} = create_token(%{})

      assert errors_on(changeset) == %{
               type: ["can't be blank"],
               secret_fragment: ["can't be blank"],
               secret_hash: ["can't be blank"]
             }
    end

    test "returns errors on invalid attrs" do
      attrs = %{
        type: :foo,
        secret_nonce: -1,
        secret_fragment: -1,
        expires_at: DateTime.utc_now(),
        created_by_user_agent: -1,
        created_by_remote_ip: -1,
        account_id: Ecto.UUID.generate()
      }

      assert {:error, changeset} = create_token(attrs)

      assert %{
               type: ["is invalid"],
               expires_at: ["must be greater than" <> _],
               secret_nonce: ["is invalid"],
               secret_fragment: ["is invalid"],
               secret_hash: ["can't be blank"],
               created_by_remote_ip: ["is invalid"],
               created_by_user_agent: ["is invalid"]
             } = errors_on(changeset)
    end

    test "inserts a token", %{account: account, actor: actor, identity: identity} do
      type = :email
      nonce = "nonce"
      fragment = Domain.Crypto.random_token(32)
      expires_at = DateTime.utc_now() |> DateTime.add(1, :day)
      user_agent = Fixtures.Tokens.user_agent()
      remote_ip = Fixtures.Tokens.remote_ip()

      attrs = %{
        type: type,
        account_id: account.id,
        actor_id: actor.id,
        identity_id: identity.id,
        secret_nonce: nonce,
        secret_fragment: fragment,
        expires_at: expires_at,
        created_by_user_agent: user_agent,
        created_by_remote_ip: remote_ip
      }

      assert {:ok, %Tokens.Token{} = token} = create_token(attrs)

      assert token.type == type
      assert token.expires_at == expires_at
      assert token.created_by_user_agent == user_agent
      assert token.created_by_remote_ip.address == remote_ip

      refute token.secret_nonce
      assert token.secret_fragment == fragment
      assert token.secret_salt
      assert token.secret_hash

      assert token.account_id == account.id
      assert token.actor_id == actor.id
      assert token.identity_id == identity.id
      assert token.created_by_subject == %{"name" => "System", "email" => nil}
    end
  end

  describe "create_token/3" do
    test "returns errors on missing required attrs", %{subject: subject} do
      assert {:error, changeset} = create_token(%{}, subject)

      assert errors_on(changeset) == %{
               type: ["can't be blank"],
               secret_fragment: ["can't be blank"],
               secret_hash: ["can't be blank"]
             }
    end

    test "returns errors on invalid attrs", %{subject: subject} do
      attrs = %{
        type: -1,
        secret_nonce: "x.o",
        secret_fragment: -1,
        expires_at: DateTime.utc_now(),
        created_by_user_agent: -1,
        created_by_remote_ip: -1
      }

      assert {:error, changeset} = create_token(attrs, subject)

      assert %{
               type: ["is invalid"],
               expires_at: ["must be greater than" <> _],
               secret_nonce: ["has invalid format"],
               secret_fragment: ["is invalid"],
               secret_hash: ["can't be blank"],
               created_by_remote_ip: ["is invalid"],
               created_by_user_agent: ["is invalid"]
             } = errors_on(changeset)
    end

    test "inserts a token", %{
      account: account,
      actor: actor,
      identity: identity,
      subject: subject
    } do
      type = :client
      nonce = "nonce"
      fragment = Domain.Crypto.random_token(32)
      expires_at = DateTime.utc_now() |> DateTime.add(1, :day)

      attrs = %{
        type: type,
        secret_nonce: nonce,
        secret_fragment: fragment,
        actor_id: actor.id,
        identity_id: identity.id,
        expires_at: expires_at
      }

      assert {:ok, %Tokens.Token{} = token} = create_token(attrs, subject)

      assert token.type == type
      assert token.expires_at == expires_at
      assert token.created_by_user_agent == subject.context.user_agent
      assert token.created_by_remote_ip == subject.context.remote_ip

      assert token.secret_fragment == fragment
      refute token.secret_nonce
      assert token.secret_salt
      assert token.secret_hash

      assert Domain.Crypto.equal?(
               :sha3_256,
               nonce <> fragment <> token.secret_salt,
               token.secret_hash
             )

      assert token.account_id == account.id
      assert token.actor_id == actor.id
      assert token.identity_id == identity.id

      assert token.created_by_subject == %{
               "name" => actor.name,
               "email" => identity.email
             }
    end
  end

  describe "use_token/4" do
    test "returns token when nonce, context and secret are valid", %{account: account} do
      nonce = "nonce"
      token = Fixtures.Tokens.create_token(account: account, secret_nonce: nonce)
      context = Fixtures.Auth.build_context(type: token.type)
      encoded_fragment = encode_fragment!(token)

      assert {:ok, used_token} = use_token(nonce <> encoded_fragment, context)
      assert used_token.account_id == account.id
      assert used_token.id == token.id
    end

    test "updates last seen fields when token is used", %{account: account} do
      nonce = "nonce"
      token = Fixtures.Tokens.create_token(account: account, secret_nonce: nonce)
      context = Fixtures.Auth.build_context(type: token.type)
      encoded_fragment = encode_fragment!(token)

      assert {:ok, token} = use_token(nonce <> encoded_fragment, context)

      assert token.last_seen_user_agent == context.user_agent
      assert token.last_seen_remote_ip.address == context.remote_ip
      assert token.last_seen_remote_ip_location_region == context.remote_ip_location_region
      assert token.last_seen_remote_ip_location_city == context.remote_ip_location_city
      assert token.last_seen_remote_ip_location_lat == context.remote_ip_location_lat
      assert token.last_seen_remote_ip_location_lon == context.remote_ip_location_lon
      assert token.last_seen_at
      refute token.remaining_attempts
    end

    test "returns error when secret is invalid", %{account: account} do
      nonce = "nonce"
      token = Fixtures.Tokens.create_token(account: account, secret_nonce: nonce)
      context = Fixtures.Auth.build_context(type: token.type)
      encoded_fragment = encode_fragment!(%{token | secret_fragment: "bar"})

      assert use_token(nonce <> encoded_fragment, context) ==
               {:error, :invalid_or_expired_token}
    end

    test "reduces attempts count when secret is invalid", %{account: account} do
      nonce = "nonce"

      token =
        Fixtures.Tokens.create_token(
          remaining_attempts: 3,
          expires_at: nil,
          account: account,
          secret_nonce: nonce
        )

      context = Fixtures.Auth.build_context(type: token.type)
      encoded_fragment = encode_fragment!(%{token | secret_fragment: "bar"})

      assert use_token(nonce <> encoded_fragment, context) ==
               {:error, :invalid_or_expired_token}

      token = Repo.get(Tokens.Token, token.id)
      assert token.remaining_attempts == 2
      refute token.expires_at
    end

    test "expires token when attempts limit is exceeded", %{account: account} do
      nonce = "nonce"

      token =
        Fixtures.Tokens.create_token(
          remaining_attempts: 1,
          expires_at: nil,
          account: account,
          secret_nonce: nonce
        )

      context = Fixtures.Auth.build_context(type: token.type)
      encoded_fragment = encode_fragment!(%{token | secret_fragment: "bar"})

      assert use_token(nonce <> encoded_fragment, context) ==
               {:error, :invalid_or_expired_token}

      token = Repo.get(Tokens.Token, token.id)
      assert token.remaining_attempts == 0
      assert token.expires_at
    end

    test "returns error when nonce is invalid", %{account: account} do
      token = Fixtures.Tokens.create_token(account: account)
      context = Fixtures.Auth.build_context(type: token.type)
      encoded_fragment = encode_fragment!(token)

      assert use_token("foo" <> encoded_fragment, context) ==
               {:error, :invalid_or_expired_token}
    end

    test "returns error when signed token is invalid", %{account: account} do
      token = Fixtures.Tokens.create_token(account: account)
      context = Fixtures.Auth.build_context(type: token.type)

      assert use_token("nonce.bar", context) == {:error, :invalid_or_expired_token}
      assert use_token("bar", context) == {:error, :invalid_or_expired_token}
      assert use_token("", context) == {:error, :invalid_or_expired_token}
    end

    test "returns error when type is invalid", %{account: account} do
      nonce = "nonce"
      token = Fixtures.Tokens.create_token(account: account, secret_nonce: nonce)
      context = Fixtures.Auth.build_context(type: :other)
      encoded_fragment = encode_fragment!(token)

      assert use_token(nonce <> encoded_fragment, context) ==
               {:error, :invalid_or_expired_token}
    end
  end

  describe "update_token/2" do
    setup %{account: account} do
      token = Fixtures.Tokens.create_token(account: account)

      %{token: token}
    end

    test "no-op on empty attrs", %{token: token} do
      assert {:ok, refreshed_token} = update_token(token, %{})
      assert refreshed_token.expires_at == token.expires_at
    end

    test "returns errors on invalid attrs", %{token: token} do
      attrs = %{
        expires_at: DateTime.utc_now()
      }

      assert {:error, changeset} = update_token(token, attrs)

      assert %{
               expires_at: ["must be greater than" <> _]
             } = errors_on(changeset)
    end

    test "updates token expiration", %{token: token} do
      attrs = %{
        expires_at: DateTime.utc_now() |> DateTime.add(1, :day)
      }

      assert {:ok, token} = update_token(token, attrs)
      assert token == %{token | expires_at: attrs.expires_at}
    end

    test "does not extend expiration of expired tokens", %{token: token} do
      token = Fixtures.Tokens.expire_token(token)
      assert update_token(token, %{}) == {:error, :not_found}
    end

    test "does not extend expiration of deleted tokens", %{token: token} do
      token = Fixtures.Tokens.delete_token(token)
      assert update_token(token, %{}) == {:error, :not_found}
    end
  end

  describe "delete_token/2" do
    test "admin can delete any account token", %{account: account, subject: subject} do
      token = Fixtures.Tokens.create_token(account: account)
      Phoenix.PubSub.subscribe(Domain.PubSub, "sessions:#{token.id}")

      assert {:ok, token} = delete_token(token, subject)

      assert token.deleted_at
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "user can delete own token", %{account: account, identity: identity, subject: subject} do
      token = Fixtures.Tokens.create_token(account: account, identity: identity)
      Phoenix.PubSub.subscribe(Domain.PubSub, "sessions:#{token.id}")

      assert {:ok, token} = delete_token(token, subject)

      assert token.deleted_at
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "user cannot delete other users token", %{
      account: account
    } do
      actor = Fixtures.Actors.create_actor(type: :account_user, account: account)
      subject = Fixtures.Auth.create_subject(account: account, actor: actor)

      token = Fixtures.Tokens.create_token(account: account)
      Phoenix.PubSub.subscribe(Domain.PubSub, "sessions:#{token.id}")

      assert delete_token(token, subject) == {:error, :not_found}

      refute Repo.get(Tokens.Token, token.id).deleted_at
      refute_receive "disconnect"
    end

    test "does not delete tokens that belong to other accounts", %{
      subject: subject
    } do
      token = Fixtures.Tokens.create_token()
      Phoenix.PubSub.subscribe(Domain.PubSub, "sessions:#{token.id}")

      assert delete_token(token, subject) == {:error, :not_found}

      refute Repo.get(Tokens.Token, token.id).deleted_at
      refute_receive "disconnect"
    end

    test "returns error when subject does not have required permissions", %{
      account: account,
      subject: subject
    } do
      token = Fixtures.Tokens.create_token(account: account)
      subject = Fixtures.Auth.remove_permissions(subject)

      assert delete_token(token, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [
                   {:one_of,
                    [
                      Tokens.Authorizer.manage_tokens_permission(),
                      Tokens.Authorizer.manage_own_tokens_permission()
                    ]}
                 ]}}
    end
  end

  describe "delete_token_for/1" do
    test "deletes tokens for given subject", %{
      account: account,
      identity: identity,
      subject: subject
    } do
      other_token = Fixtures.Tokens.create_token(account: account, identity: identity)
      Phoenix.PubSub.subscribe(Domain.PubSub, "sessions:#{subject.token_id}")

      assert {:ok, deleted_token} = delete_token_for(subject)
      assert deleted_token.id == subject.token_id

      assert Repo.get(Tokens.Token, subject.token_id).deleted_at
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}

      refute Repo.get(Tokens.Token, other_token.id).deleted_at
    end

    test "expires flows for given subject", %{
      account: account,
      identity: identity,
      subject: subject
    } do
      Fixtures.Flows.create_flow(
        account: account,
        identity: identity,
        subject: subject
      )

      assert {:ok, _token} = delete_token_for(subject)

      expires_at = Repo.one(Domain.Flows.Flow).expires_at
      assert DateTime.diff(expires_at, DateTime.utc_now()) <= 1
    end

    test "does not delete tokens for other actors", %{account: account, subject: subject} do
      token = Fixtures.Tokens.create_token(account: account)
      Phoenix.PubSub.subscribe(Domain.PubSub, "sessions:#{token.id}")

      assert {:ok, _token} = delete_token_for(subject)

      refute Repo.get(Tokens.Token, token.id).deleted_at
      refute_receive "disconnect"
    end
  end

  describe "delete_tokens_for/1" do
    test "deletes browser tokens for given identity", %{account: account} do
      actor = Fixtures.Actors.create_actor(account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      token = Fixtures.Tokens.create_token(type: :browser, account: account, identity: identity)
      Phoenix.PubSub.subscribe(Domain.PubSub, "sessions:#{token.id}")

      assert {:ok, [_token]} = delete_tokens_for(identity)

      assert Repo.get(Tokens.Token, token.id).deleted_at
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end
  end

  describe "delete_tokens_for/2" do
    test "deletes browser tokens for given actor", %{account: account, subject: subject} do
      actor = Fixtures.Actors.create_actor(account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      token = Fixtures.Tokens.create_token(type: :browser, account: account, identity: identity)
      Phoenix.PubSub.subscribe(Domain.PubSub, "sessions:#{token.id}")

      assert {:ok, [_token]} = delete_tokens_for(actor, subject)

      assert Repo.get(Tokens.Token, token.id).deleted_at
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "deletes client tokens for given actor", %{account: account, subject: subject} do
      actor = Fixtures.Actors.create_actor(account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      token = Fixtures.Tokens.create_token(type: :client, account: account, identity: identity)
      Phoenix.PubSub.subscribe(Domain.PubSub, "sessions:#{token.id}")

      assert {:ok, [_token]} = delete_tokens_for(actor, subject)

      assert Repo.get(Tokens.Token, token.id).deleted_at
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "deletes client tokens for given identity", %{account: account, subject: subject} do
      actor = Fixtures.Actors.create_actor(account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      token = Fixtures.Tokens.create_token(type: :client, account: account, identity: identity)
      Phoenix.PubSub.subscribe(Domain.PubSub, "sessions:#{token.id}")

      assert {:ok, [_token]} = delete_tokens_for(identity, subject)

      assert Repo.get(Tokens.Token, token.id).deleted_at
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "deletes client tokens for given provider", %{account: account, subject: subject} do
      actor = Fixtures.Actors.create_actor(account: account)
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider, actor: actor)
      token = Fixtures.Tokens.create_token(type: :client, account: account, identity: identity)
      Phoenix.PubSub.subscribe(Domain.PubSub, "sessions:#{token.id}")

      assert {:ok, [_token]} = delete_tokens_for(provider, subject)

      assert Repo.get(Tokens.Token, token.id).deleted_at
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "deletes gateway group tokens", %{account: account, subject: subject} do
      group = Fixtures.Gateways.create_group(account: account)
      token = Fixtures.Gateways.create_token(account: account, group: group)
      Phoenix.PubSub.subscribe(Domain.PubSub, "sessions:#{token.id}")

      assert {:ok, [_token]} = delete_tokens_for(group, subject)

      assert Repo.get(Tokens.Token, token.id).deleted_at
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "deletes relay group tokens", %{account: account, subject: subject} do
      group = Fixtures.Relays.create_group(account: account)
      token = Fixtures.Relays.create_token(account: account, group: group)
      Phoenix.PubSub.subscribe(Domain.PubSub, "sessions:#{token.id}")

      assert {:ok, [_token]} = delete_tokens_for(group, subject)

      assert Repo.get(Tokens.Token, token.id).deleted_at
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "returns error when subject does not have required permissions", %{
      actor: actor,
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert delete_tokens_for(actor, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Tokens.Authorizer.manage_tokens_permission()]}}
    end
  end

  describe "delete_expired_tokens/0" do
    test "deletes expired tokens" do
      token =
        Fixtures.Tokens.create_token()
        |> Fixtures.Tokens.expire_token()

      Phoenix.PubSub.subscribe(Domain.PubSub, "sessions:#{token.id}")

      assert {:ok, [_token]} = delete_expired_tokens()

      assert Repo.get(Tokens.Token, token.id).deleted_at
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "does not delete non-expired tokens" do
      in_one_minute = DateTime.utc_now() |> DateTime.add(1, :minute)
      token = Fixtures.Tokens.create_token(expires_at: in_one_minute)
      Phoenix.PubSub.subscribe(Domain.PubSub, "sessions:#{token.id}")

      assert delete_expired_tokens() == {:ok, []}

      refute Repo.get(Tokens.Token, token.id).deleted_at
      refute_receive "disconnect"
    end
  end
end
