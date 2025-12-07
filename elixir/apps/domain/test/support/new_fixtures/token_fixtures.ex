defmodule Domain.TokenFixtures do
  @moduledoc """
  Test helpers for creating tokens and related data.
  """

  import Domain.AccountFixtures
  import Domain.ActorFixtures
  import Domain.SiteFixtures

  @doc """
  Generate valid token attributes with sensible defaults.
  """
  def valid_token_attrs(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    Enum.into(attrs, %{
      type: :browser,
      name: "Token #{unique_num}",
      secret_salt: generate_salt(),
      secret_hash: generate_hash(),
      remaining_attempts: 3,
      # Default expiration 30 days from now
      expires_at: DateTime.add(DateTime.utc_now(), 30, :day)
    })
  end

  @doc """
  Generate a token with valid default attributes.

  The token will be created with an associated account and actor/site
  depending on the token type.

  ## Examples

      token = token_fixture()
      token = token_fixture(type: :client)
      token = token_fixture(actor: actor, type: :browser)

  """
  def token_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    # Get or create account
    account = Map.get(attrs, :account) || account_fixture()

    # Build token attrs
    token_attrs =
      attrs
      |> Map.delete(:account)
      |> Map.delete(:actor)
      |> Map.delete(:site)
      |> Map.delete(:auth_provider)
      |> valid_token_attrs()

    changeset =
      %Domain.Token{}
      |> Ecto.Changeset.cast(token_attrs, [
        :type,
        :name,
        :secret_salt,
        :secret_hash,
        :remaining_attempts,
        :last_seen_user_agent,
        :last_seen_remote_ip,
        :last_seen_remote_ip_location_region,
        :last_seen_remote_ip_location_city,
        :last_seen_remote_ip_location_lat,
        :last_seen_remote_ip_location_lon,
        :last_seen_at,
        :expires_at
      ])
      |> Ecto.Changeset.put_assoc(:account, account)
      |> Domain.Token.changeset()

    # Associate with actor for browser/client/api_client tokens
    changeset =
      if Map.get(token_attrs, :type) in [:browser, :client, :api_client] do
        actor = Map.get(attrs, :actor) || actor_fixture(account: account)
        Ecto.Changeset.put_assoc(changeset, :actor, actor)
      else
        changeset
      end

    # Associate with site for site tokens
    changeset =
      if Map.get(token_attrs, :type) == :site do
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

    Domain.Repo.insert!(changeset)
  end

  @doc """
  Generate a browser token.
  """
  def browser_token_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    token_fixture(Map.put(attrs, :type, :browser))
  end

  @doc """
  Generate a client token.
  """
  def client_token_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    token_fixture(Map.put(attrs, :type, :client))
  end

  @doc """
  Generate an API client token.
  """
  def api_client_token_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    token_fixture(Map.put(attrs, :type, :api_client))
  end

  @doc """
  Generate a relay token.
  """
  def relay_token_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    token_fixture(Map.put(attrs, :type, :relay))
  end

  @doc """
  Generate a site token (for gateway).
  """
  def site_token_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    token_fixture(Map.put(attrs, :type, :site))
  end

  @doc """
  Generate an email token.
  """
  def email_token_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    token_fixture(Map.put(attrs, :type, :email))
  end

  @doc """
  Generate an expired token.
  """
  def expired_token_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    token_fixture(Map.put(attrs, :expires_at, DateTime.add(DateTime.utc_now(), -3600, :second)))
  end

  @doc """
  Generate a token with last seen information.
  """
  def active_token_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    attrs =
      attrs
      |> Map.put_new(:last_seen_at, DateTime.utc_now())
      |> Map.put_new(:last_seen_user_agent, "Mozilla/5.0")
      |> Map.put_new(:last_seen_remote_ip, {100, 64, 0, 1})

    token_fixture(attrs)
  end

  @doc """
  Generate a token with no remaining attempts.
  """
  def exhausted_token_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    token_fixture(Map.put(attrs, :remaining_attempts, 0))
  end

  @doc """
  Create a token that can be encoded and verified.

  Returns `{token, encoded_token}` where `encoded_token` is the full
  token string including any nonce prefix.

  ## Options

    * `:type` - Token type (default: `:browser`)
    * `:account` - Account to associate with the token
    * `:actor` - Actor for browser/client/api_client/email tokens
    * `:site` - Site for site tokens
    * `:nonce` - Nonce prefix (default: "")
    * `:expires_at` - Token expiration time

  """
  def encodable_token_fixture(attrs \\ %{}) do
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

    # Get or create actor for types that need it
    actor =
      if type in [:browser, :client, :api_client, :email] do
        Map.get(attrs, :actor) || actor_fixture(account: account)
      else
        nil
      end

    # Get or create site for site tokens
    site =
      if type == :site do
        Map.get(attrs, :site) || site_fixture(account: account)
      else
        nil
      end

    # Get auth_provider_id if provided
    auth_provider_id = Map.get(attrs, :auth_provider_id)

    token_attrs = %{
      type: type,
      name: "Token #{System.unique_integer([:positive])}",
      secret_salt: secret_salt,
      secret_hash: secret_hash,
      remaining_attempts: Map.get(attrs, :remaining_attempts, 3),
      expires_at: Map.get(attrs, :expires_at, DateTime.add(DateTime.utc_now(), 30, :day)),
      auth_provider_id: auth_provider_id
    }

    changeset =
      %Domain.Token{}
      |> Ecto.Changeset.cast(token_attrs, [
        :type,
        :name,
        :secret_salt,
        :secret_hash,
        :remaining_attempts,
        :expires_at,
        :auth_provider_id
      ])
      |> Domain.Token.changeset()

    changeset =
      if account, do: Ecto.Changeset.put_assoc(changeset, :account, account), else: changeset

    changeset = if actor, do: Ecto.Changeset.put_assoc(changeset, :actor, actor), else: changeset
    changeset = if site, do: Ecto.Changeset.put_assoc(changeset, :site, site), else: changeset

    token = Domain.Repo.insert!(changeset)
    encoded_token = nonce <> encode_fragment(token, secret_fragment)

    {token, encoded_token}
  end

  # Private helpers

  defp generate_salt do
    :crypto.strong_rand_bytes(16)
    |> Base.encode64()
  end

  defp generate_hash do
    :crypto.strong_rand_bytes(32)
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

  defp encode_fragment(token, secret_fragment) do
    config = Application.fetch_env!(:domain, Domain.Tokens)
    key_base = Keyword.fetch!(config, :key_base)
    salt = Keyword.fetch!(config, :salt) <> to_string(token.type)
    body = {token.account_id, token.id, secret_fragment}

    "." <> Plug.Crypto.sign(key_base, salt, body)
  end
end
