defmodule Domain.TokensTest do
  use Domain.DataCase, async: true
  import Domain.Tokens
  alias Domain.Tokens

  setup do
    account = Fixtures.Accounts.create_account()
    subject = Fixtures.Auth.create_subject(account: account)
    %{account: account, subject: subject}
  end

  describe "create_token/2" do
    test "returns errors on missing required attrs" do
      assert {:error, changeset} = create_token(%{})

      assert errors_on(changeset) == %{
               type: ["can't be blank"],
               account_id: ["can't be blank"],
               expires_at: ["can't be blank"],
               secret: ["can't be blank"],
               secret_hash: ["can't be blank"],
               created_by_remote_ip: ["can't be blank"],
               created_by_user_agent: ["can't be blank"]
             }
    end

    test "returns errors on invalid attrs" do
      attrs = %{
        type: :relay,
        secret: -1,
        expires_at: DateTime.utc_now(),
        created_by_user_agent: -1,
        created_by_remote_ip: -1,
        account_id: Ecto.UUID.generate()
      }

      assert {:error, changeset} = create_token(attrs)

      assert %{
               type: ["is invalid"],
               expires_at: ["must be greater than" <> _],
               secret: ["is invalid"],
               secret_hash: ["can't be blank"],
               created_by_remote_ip: ["is invalid"],
               created_by_user_agent: ["is invalid"]
             } = errors_on(changeset)
    end

    test "inserts a token", %{account: account} do
      type = :email
      secret = Domain.Crypto.random_token(32)
      expires_at = DateTime.utc_now() |> DateTime.add(1, :day)
      user_agent = Fixtures.Tokens.user_agent()
      remote_ip = Fixtures.Tokens.remote_ip()

      attrs = %{
        type: type,
        account_id: account.id,
        secret: secret,
        expires_at: expires_at,
        created_by_user_agent: user_agent,
        created_by_remote_ip: remote_ip
      }

      assert {:ok, %Tokens.Token{} = token} = create_token(attrs)

      assert token.type == type
      assert token.expires_at == expires_at
      assert token.created_by_user_agent == user_agent
      assert token.created_by_remote_ip.address == remote_ip

      assert token.secret == secret
      assert token.secret_salt
      assert token.secret_hash

      assert token.account_id == account.id
    end
  end

  describe "create_token/3" do
    test "returns errors on missing required attrs", %{subject: subject} do
      assert {:error, changeset} = create_token(%{}, subject)

      assert errors_on(changeset) == %{
               type: ["can't be blank"],
               expires_at: ["can't be blank"],
               secret: ["can't be blank"],
               secret_hash: ["can't be blank"],
               created_by_remote_ip: ["can't be blank"],
               created_by_user_agent: ["can't be blank"]
             }
    end

    test "returns errors on invalid attrs", %{subject: subject} do
      attrs = %{
        type: -1,
        secret: -1,
        expires_at: DateTime.utc_now(),
        created_by_user_agent: -1,
        created_by_remote_ip: -1
      }

      assert {:error, changeset} = create_token(attrs, subject)

      assert %{
               type: ["is invalid"],
               expires_at: ["must be greater than" <> _],
               secret: ["is invalid"],
               secret_hash: ["can't be blank"],
               created_by_remote_ip: ["is invalid"],
               created_by_user_agent: ["is invalid"]
             } = errors_on(changeset)
    end

    test "inserts a token", %{account: account, subject: subject} do
      type = :client
      secret = Domain.Crypto.random_token(32)
      expires_at = DateTime.utc_now() |> DateTime.add(1, :day)
      user_agent = Fixtures.Tokens.user_agent()
      remote_ip = Fixtures.Tokens.remote_ip()

      attrs = %{
        type: type,
        secret: secret,
        expires_at: expires_at,
        created_by_user_agent: user_agent,
        created_by_remote_ip: remote_ip
      }

      assert {:ok, %Tokens.Token{} = token} = create_token(attrs, subject)

      assert token.type == type
      assert token.expires_at == expires_at
      assert token.created_by_user_agent == user_agent
      assert token.created_by_remote_ip.address == remote_ip

      assert token.secret == secret
      assert token.secret_salt
      assert token.secret_hash

      assert Domain.Crypto.equal?(:sha, secret <> token.secret_salt, token.secret_hash)

      assert token.account_id == account.id
    end
  end

  describe "use_token/4" do
    test "returns token when context and secret are valid", %{account: account} do
      token = Fixtures.Tokens.create_token(account: account)
      context = Fixtures.Auth.build_context(type: token.type)
      encoded_token = encode_token!(token)

      assert {:ok, _token} = use_token(account.id, encoded_token, context)
    end

    test "updates last seen fields when token is used", %{account: account} do
      token = Fixtures.Tokens.create_token(account: account)
      context = Fixtures.Auth.build_context(type: token.type)
      encoded_token = encode_token!(token)

      assert {:ok, token} = use_token(account.id, encoded_token, context)

      assert token.last_seen_user_agent == context.user_agent
      assert token.last_seen_remote_ip.address == context.remote_ip
      assert token.last_seen_remote_ip_location_region == context.remote_ip_location_region
      assert token.last_seen_remote_ip_location_city == context.remote_ip_location_city
      assert token.last_seen_remote_ip_location_lat == context.remote_ip_location_lat
      assert token.last_seen_remote_ip_location_lon == context.remote_ip_location_lon
      assert token.last_seen_at
    end

    test "returns error when secret is invalid", %{account: account} do
      token = Fixtures.Tokens.create_token(account: account)
      context = Fixtures.Auth.build_context(type: token.type)
      encoded_token = encode_token!(%{token | secret: "bar"})

      assert use_token(account.id, encoded_token, context) ==
               {:error, :invalid_or_expired_token}
    end

    test "returns error when account_id is invalid", %{account: account} do
      token = Fixtures.Tokens.create_token(account: account)
      context = Fixtures.Auth.build_context(type: token.type)
      encoded_token = encode_token!(%{token | account_id: Ecto.UUID.generate()})

      assert use_token(account.id, encoded_token, context) ==
               {:error, :invalid_or_expired_token}
    end

    test "returns error when signed token is invalid", %{account: account} do
      token = Fixtures.Tokens.create_token(account: account)
      context = Fixtures.Auth.build_context(type: token.type)

      assert use_token(account.id, "bar", context) == {:error, :invalid_or_expired_token}
    end

    test "returns error when type is invalid", %{account: account} do
      token = Fixtures.Tokens.create_token(account: account)
      context = Fixtures.Auth.build_context(type: :other)
      encoded_token = encode_token!(token)

      assert use_token(account.id, encoded_token, context) ==
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

  describe "delete_token/1" do
    test "marks token as deleted" do
      token = Fixtures.Tokens.create_token()
      assert {:ok, token} = delete_token(token)
      assert token.deleted_at
      assert Repo.get(Tokens.Token, token.id).deleted_at
    end

    test "returns error when token is already deleted" do
      token = Fixtures.Tokens.create_token()
      token = Fixtures.Tokens.delete_token(token)
      assert delete_token(token) == {:error, :not_found}
    end
  end
end
