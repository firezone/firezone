defmodule Domain.TokenFixtures do
  @moduledoc """
  Test helpers for creating tokens and related data.
  """

  import Domain.AccountFixtures
  import Domain.ActorFixtures
  import Domain.SiteFixtures

  @doc """
  Generate a token with valid default attributes.

  Returns the token with `secret_fragment` populated as a virtual field.
  Use `encode_token/1` or `encode_token/2` to get the encoded string.

  ## Options

    * `:type` - Token type (default: `:browser`)
    * `:account` - Account to associate with the token
    * `:actor` - Actor for browser/client/api_client tokens
    * `:site` - Site for site tokens
    * `:secret_fragment` - Custom secret fragment (generated if not provided)
    * `:nonce` - Nonce for hash computation (default: "")
    * `:expires_at` - Token expiration time

  ## Examples

      token = token_fixture()
      token = client_token_fixture()
      encoded = encode_token(token)

  """
  def token_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    type = Map.get(attrs, :type, :browser)
    name = Map.get(attrs, :name, "Token #{System.unique_integer([:positive])}")
    remaining_attempts = Map.get(attrs, :remaining_attempts, 0)
    nonce = Map.get(attrs, :nonce, "")
    expires_at = Map.get(attrs, :expires_at, DateTime.add(DateTime.utc_now(), 30, :day))
    secret_fragment = Map.get(attrs, :secret_fragment, generate_secret_fragment())
    secret_salt = generate_salt()
    secret_hash = compute_secret_hash(nonce, secret_fragment, secret_salt)

    token_attrs = %{
      type: type,
      name: name,
      secret_nonce: nonce,
      secret_salt: secret_salt,
      secret_hash: secret_hash,
      remaining_attempts: remaining_attempts,
      expires_at: expires_at
    }

    # Get or create account (relay tokens don't have accounts)
    account =
      if type == :relay do
        nil
      else
        Map.get(attrs, :account) || account_fixture()
      end

    changeset =
      %Domain.Token{}
      |> Ecto.Changeset.cast(token_attrs, [
        :type,
        :name,
        :secret_nonce,
        :secret_salt,
        :secret_hash,
        :remaining_attempts,
        :expires_at
      ])

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

    # Set the virtual field so encode_token can use it
    %{token | secret_fragment: secret_fragment, secret_nonce: nonce}
  end

  @doc """
  Generate a browser token (default type).
  """
  def browser_token_fixture(attrs \\ %{}) do
    attrs |> Enum.into(%{}) |> Map.put(:type, :browser) |> token_fixture()
  end

  @doc """
  Generate a client token.
  """
  def client_token_fixture(attrs \\ %{}) do
    attrs |> Enum.into(%{}) |> Map.put(:type, :client) |> token_fixture()
  end

  @doc """
  Generate an API client token.
  """
  def api_client_token_fixture(attrs \\ %{}) do
    attrs |> Enum.into(%{}) |> Map.put(:type, :api_client) |> token_fixture()
  end

  @doc """
  Generate a relay token. Expires at nil (infinity).
  """
  def relay_token_fixture(attrs \\ %{}) do
    attrs
    |> Enum.into(%{})
    |> Map.put(:type, :relay)
    |> Map.put_new(:expires_at, nil)
    |> token_fixture()
  end

  @doc """
  Generate a site/gateway token. Expires at nil (infinity).
  """
  def site_token_fixture(attrs \\ %{}) do
    attrs
    |> Enum.into(%{})
    |> Map.put(:type, :site)
    |> Map.put_new(:expires_at, nil)
    |> token_fixture()
  end

  @doc """
  Generate an email token.
  """
  def email_token_fixture(attrs \\ %{}) do
    attrs |> Enum.into(%{}) |> Map.put(:type, :email) |> token_fixture()
  end

  @doc """
  Encode a token for use in authentication.

  Reads the `secret_fragment` and `secret_nonce` from the token's virtual fields.
  """
  def encode_token(token) do
    config = Domain.Config.fetch_env!(:domain, Domain.Tokens)
    key_base = Keyword.fetch!(config, :key_base)
    salt = Keyword.fetch!(config, :salt) <> to_string(token.type)
    body = {token.account_id, token.id, token.secret_fragment}
    nonce = token.secret_nonce || ""

    nonce <> "." <> Plug.Crypto.sign(key_base, salt, body)
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
end
