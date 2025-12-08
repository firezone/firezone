defmodule Domain.TokenFixtures do
  @moduledoc """
  Test helpers for creating tokens and related data.
  """

  import Domain.AccountFixtures
  import Domain.ActorFixtures
  import Domain.SiteFixtures

  @doc """
  Generate a token with valid default attributes.

  Returns `{token, encoded}` where `encoded` is the token string for authentication.

  The token will be created with an associated account and actor/site
  depending on the token type.

  ## Options

    * `:type` - Token type (default: `:browser`)
    * `:account` - Account to associate with the token
    * `:actor` - Actor for browser/client/api_client tokens
    * `:site` - Site for site tokens
    * `:nonce` - Nonce prefix for the encoded token (default: "")
    * `:expires_at` - Token expiration time

  ## Examples

      {token, encoded} = token_fixture()
      {token, encoded} = token_fixture(type: :client)
      {token, encoded} = token_fixture(actor: actor, type: :browser)

  """
  def token_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    type = Map.get(attrs, :type, :browser)
    nonce = Map.get(attrs, :nonce, "")
    secret_fragment = generate_secret_fragment()
    secret_salt = generate_salt()
    secret_hash = compute_secret_hash(nonce, secret_fragment, secret_salt)

    # Get or create account (relay tokens don't have accounts)
    account =
      if type == :relay do
        nil
      else
        Map.get(attrs, :account) || account_fixture()
      end

    token_attrs = %{
      type: type,
      name: "Token #{System.unique_integer([:positive])}",
      secret_salt: secret_salt,
      secret_hash: secret_hash,
      remaining_attempts: Map.get(attrs, :remaining_attempts, 3),
      expires_at: Map.get(attrs, :expires_at, DateTime.add(DateTime.utc_now(), 30, :day))
    }

    changeset =
      %Domain.Token{}
      |> Ecto.Changeset.cast(token_attrs, [
        :type,
        :name,
        :secret_salt,
        :secret_hash,
        :remaining_attempts,
        :expires_at
      ])
      |> Domain.Token.changeset()

    changeset =
      if account, do: Ecto.Changeset.put_assoc(changeset, :account, account), else: changeset

    # Associate with actor for browser/client/api_client/email tokens
    changeset =
      if type in [:browser, :client, :api_client, :email] do
        actor = Map.get(attrs, :actor) || actor_fixture(account: account)
        Ecto.Changeset.put_assoc(changeset, :actor, actor)
      else
        changeset
      end

    # Associate with site for site tokens
    changeset =
      if type == :site do
        site = Map.get(attrs, :site) || site_fixture(account: account)
        Ecto.Changeset.put_assoc(changeset, :site, site)
      else
        changeset
      end

    # Optionally associate with auth_provider
    changeset =
      if auth_provider = Map.get(attrs, :auth_provider) do
        Ecto.Changeset.put_assoc(changeset, :auth_provider, auth_provider)
      else
        changeset
      end

    token = Domain.Repo.insert!(changeset)
    encoded = encode_token(token, secret_fragment, nonce)

    {token, encoded}
  end

  # Private helpers

  defp generate_salt do
    :crypto.strong_rand_bytes(16)
    |> Base.encode64()
  end

  defp generate_secret_fragment do
    :crypto.strong_rand_bytes(32)
    |> Base.hex_encode32(case: :upper, padding: true)
  end

  defp compute_secret_hash(nonce, fragment, salt) do
    :crypto.hash(:sha3_256, nonce <> fragment <> salt)
    |> Base.encode16(case: :lower)
  end

  defp encode_token(token, secret_fragment, nonce) do
    config = Application.fetch_env!(:domain, Domain.Tokens)
    key_base = Keyword.fetch!(config, :key_base)
    salt = Keyword.fetch!(config, :salt) <> to_string(token.type)
    body = {token.account_id, token.id, secret_fragment}

    nonce <> "." <> Plug.Crypto.sign(key_base, salt, body)
  end
end
