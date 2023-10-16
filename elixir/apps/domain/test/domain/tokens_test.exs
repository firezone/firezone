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
    test "returns errors on missing required attrs", %{account: account} do
      assert {:error, changeset} = create_token(account, %{})

      assert errors_on(changeset) == %{
               context: ["can't be blank"],
               expires_at: ["can't be blank"],
               remote_ip: ["can't be blank"],
               secret: ["can't be blank"],
               secret_hash: ["can't be blank"],
               user_agent: ["can't be blank"]
             }
    end

    test "returns errors on invalid attrs", %{account: account} do
      attrs = %{
        context: :relay,
        secret: -1,
        expires_at: DateTime.utc_now(),
        user_agent: -1,
        remote_ip: -1
      }

      assert {:error, changeset} = create_token(account, attrs)

      assert %{
               context: ["is invalid"],
               expires_at: ["must be greater than" <> _],
               remote_ip: ["is invalid"],
               secret: ["is invalid"],
               secret_hash: ["can't be blank"],
               user_agent: ["is invalid"]
             } = errors_on(changeset)
    end

    test "inserts a token", %{account: account} do
      context = :email
      secret = Domain.Crypto.random_token(32)
      expires_at = DateTime.utc_now() |> DateTime.add(1, :day)
      user_agent = Fixtures.Tokens.user_agent()
      remote_ip = Fixtures.Tokens.remote_ip()

      attrs = %{
        context: context,
        secret: secret,
        expires_at: expires_at,
        user_agent: user_agent,
        remote_ip: remote_ip
      }

      assert {:ok, %Tokens.Token{} = token} = create_token(account, attrs)

      assert token.context == context
      assert token.expires_at == expires_at
      assert token.user_agent == user_agent
      assert token.remote_ip.address == remote_ip

      assert token.secret == secret
      assert token.secret_salt
      assert token.secret_hash

      assert token.account_id == account.id
    end
  end

  describe "create_token/3" do
    test "returns errors on missing required attrs", %{account: account, subject: subject} do
      assert {:error, changeset} = create_token(account, %{}, subject)

      assert errors_on(changeset) == %{
               context: ["can't be blank"],
               expires_at: ["can't be blank"],
               remote_ip: ["can't be blank"],
               secret: ["can't be blank"],
               secret_hash: ["can't be blank"],
               user_agent: ["can't be blank"]
             }
    end

    test "returns errors on invalid attrs", %{account: account, subject: subject} do
      attrs = %{
        context: -1,
        secret: -1,
        expires_at: DateTime.utc_now(),
        user_agent: -1,
        remote_ip: -1
      }

      assert {:error, changeset} = create_token(account, attrs, subject)

      assert %{
               context: ["is invalid"],
               expires_at: ["must be greater than" <> _],
               remote_ip: ["is invalid"],
               secret: ["is invalid"],
               secret_hash: ["can't be blank"],
               user_agent: ["is invalid"]
             } = errors_on(changeset)
    end

    test "inserts a token", %{account: account, subject: subject} do
      context = :browser
      secret = Domain.Crypto.random_token(32)
      expires_at = DateTime.utc_now() |> DateTime.add(1, :day)
      user_agent = Fixtures.Tokens.user_agent()
      remote_ip = Fixtures.Tokens.remote_ip()

      attrs = %{
        context: context,
        secret: secret,
        expires_at: expires_at,
        user_agent: user_agent,
        remote_ip: remote_ip
      }

      assert {:ok, %Tokens.Token{} = token} = create_token(account, attrs, subject)

      assert token.context == context
      assert token.expires_at == expires_at
      assert token.user_agent == user_agent
      assert token.remote_ip.address == remote_ip

      assert token.secret == secret
      assert token.secret_salt
      assert token.secret_hash

      assert Domain.Crypto.equal?(:sha, secret <> token.secret_salt, token.secret_hash)

      assert token.account_id == account.id
    end
  end

  describe "verify_token/4" do
    test "returns :ok when token context and secret are valid", %{account: account} do
      token = Fixtures.Tokens.create_token(account: account)
      encoded_token = encode_token!(token)
      assert verify_token(account.id, token.context, encoded_token) == :ok
    end

    test "returns :ok when token context, secret and UA/IP whitelists are valid", %{
      account: account
    } do
      user_agent = Fixtures.Tokens.user_agent()
      remote_ip = Fixtures.Tokens.remote_ip()

      token =
        Fixtures.Tokens.create_token(
          account: account,
          user_agent: user_agent,
          remote_ip: remote_ip
        )

      encoded_token = encode_token!(token)

      assert verify_token(account.id, token.context, encoded_token,
               user_agents_whitelist: [token.user_agent],
               remote_ips_whitelist: [token.remote_ip]
             ) == :ok
    end

    test "returns :error when user_agent doesn't match the whitelist", %{account: account} do
      user_agent = Fixtures.Tokens.user_agent() <> to_string(System.unique_integer([:positive]))

      token = Fixtures.Tokens.create_token(account: account)
      encoded_token = encode_token!(token)

      assert verify_token(account.id, token.context, encoded_token,
               user_agents_whitelist: [user_agent]
             ) ==
               {:error, :invalid_or_expired_token}
    end

    test "returns :error when remote_ip doesn't match the whitelist", %{account: account} do
      remote_ip = Fixtures.Tokens.remote_ip()

      token = Fixtures.Tokens.create_token(account: account)
      encoded_token = encode_token!(token)

      assert verify_token(account.id, token.context, encoded_token,
               remote_ips_whitelist: [remote_ip]
             ) ==
               {:error, :invalid_or_expired_token}
    end

    test "returns :error secret is invalid", %{account: account} do
      token = Fixtures.Tokens.create_token(account: account)
      encoded_token = encode_token!(%{token | secret: "bar"})

      assert verify_token(account.id, token.context, encoded_token) ==
               {:error, :invalid_or_expired_token}
    end

    test "returns :error account_id is invalid", %{account: account} do
      token = Fixtures.Tokens.create_token(account: account)
      encoded_token = encode_token!(%{token | account_id: Ecto.UUID.generate()})

      assert verify_token(account.id, token.context, encoded_token) ==
               {:error, :invalid_or_expired_token}
    end

    test "returns :error signed token is invalid", %{account: account} do
      token = Fixtures.Tokens.create_token(account: account)
      assert verify_token(account.id, token.context, "bar") == {:error, :invalid_or_expired_token}
    end

    test "returns :error context is invalid", %{account: account} do
      token = Fixtures.Tokens.create_token(account: account)
      encoded_token = encode_token!(token)

      assert verify_token(account.id, :client, encoded_token) ==
               {:error, :invalid_or_expired_token}
    end
  end

  describe "refresh_token/2" do
    setup %{account: account} do
      token = Fixtures.Tokens.create_token(account: account)

      %{token: token}
    end

    test "no-op on empty attrs", %{token: token} do
      assert {:ok, refreshed_token} = refresh_token(token, %{})
      assert refreshed_token.expires_at == token.expires_at
    end

    test "returns errors on invalid attrs", %{token: token} do
      attrs = %{
        expires_at: DateTime.utc_now()
      }

      assert {:error, changeset} = refresh_token(token, attrs)

      assert %{
               expires_at: ["must be greater than" <> _]
             } = errors_on(changeset)
    end

    test "updates token expiration", %{token: token} do
      attrs = %{
        expires_at: DateTime.utc_now() |> DateTime.add(1, :day)
      }

      assert {:ok, token} = refresh_token(token, attrs)
      assert token == %{token | expires_at: attrs.expires_at}
    end

    test "does not extend expiration of expired tokens", %{token: token} do
      token = Fixtures.Tokens.expire_token(token)
      assert refresh_token(token, %{}) == {:error, :not_found}
    end

    test "does not extend expiration of deleted tokens", %{token: token} do
      token = Fixtures.Tokens.delete_token(token)
      assert refresh_token(token, %{}) == {:error, :not_found}
    end
  end

  describe "delete_token/1" do
    test "marks token as deleted" do
      token = Fixtures.Tokens.create_token()
      assert {:ok, token} = delete_token(token)
      assert token.deleted_at
      assert Repo.one(Tokens.Token).deleted_at
    end

    test "returns error when token is already deleted" do
      token = Fixtures.Tokens.create_token()
      token = Fixtures.Tokens.delete_token(token)
      assert delete_token(token) == {:error, :not_found}
    end
  end
end
