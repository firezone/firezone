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
    attrs =
      Enum.into(attrs, %{
        type: :browser,
        name: "Token #{System.unique_integer([:positive, :monotonic])}",
        secret_nonce: "",
        secret_fragment: generate_secret_fragment(),
        secret_salt: generate_salt(),
        expires_at: DateTime.add(DateTime.utc_now(), 30, :day)
      })

    attrs
    |> Map.put_new(
      :secret_hash,
      compute_secret_hash(attrs.secret_nonce, attrs.secret_fragment, attrs.secret_salt)
    )
  end

  @doc """
  Generate a token with valid default attributes.

  Returns the token with `secret_fragment` populated as a virtual field.
  Use `encode_token/1` to get the encoded string.

  ## Examples

      token = token_fixture()
      token = client_token_fixture()
      encoded = encode_token(token)

  """
  def token_fixture(attrs \\ %{}) do
    attrs = valid_token_attrs(attrs)
    type = attrs.type

    account = Map.get(attrs, :account) || account_fixture()

    changeset =
      %Domain.Token{}
      |> Ecto.Changeset.cast(attrs, [
        :type,
        :name,
        :secret_nonce,
        :secret_fragment,
        :secret_salt,
        :secret_hash,
        :last_seen_user_agent,
        :last_seen_remote_ip,
        :last_seen_remote_ip_location_region,
        :last_seen_remote_ip_location_city,
        :last_seen_remote_ip_location_lat,
        :last_seen_remote_ip_location_lon,
        :last_seen_at,
        :expires_at
      ])

    changeset = Ecto.Changeset.put_assoc(changeset, :account, account)

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

    Domain.Repo.insert!(changeset)
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
  Generate a relay token using Domain.RelayToken schema.
  """
  def relay_token_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    secret_nonce = Map.get(attrs, :secret_nonce, generate_secret_nonce())
    secret_fragment = Map.get(attrs, :secret_fragment, generate_secret_fragment())
    secret_salt = Map.get(attrs, :secret_salt, generate_salt())
    secret_hash = compute_secret_hash(secret_nonce, secret_fragment, secret_salt)

    %Domain.RelayToken{
      secret_nonce: secret_nonce,
      secret_fragment: secret_fragment,
      secret_salt: secret_salt,
      secret_hash: secret_hash
    }
    |> Domain.Repo.insert!()
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
    attrs
    |> Enum.into(%{})
    |> Map.put(:type, :email)
    |> token_fixture()
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

  @doc """
  Encode a relay token for use in authentication.
  """
  def encode_relay_token(token) do
    config = Domain.Config.fetch_env!(:domain, Domain.Tokens)
    key_base = Keyword.fetch!(config, :key_base)
    salt = Keyword.fetch!(config, :salt) <> token_type(token)
    body = {Map.get(token, :account_id), token.id, token.secret_fragment}

    token.secret_nonce <> "." <> Plug.Crypto.sign(key_base, salt, body)
  end

  defp token_type(%Domain.RelayToken{}), do: "relay"

  # Private helpers

  defp generate_salt do
    :crypto.strong_rand_bytes(16)
    |> Base.encode64()
  end

  defp generate_secret_nonce do
    :crypto.strong_rand_bytes(8)
    |> Base.url_encode64(padding: false)
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
