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
        type: :client,
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

    # Associate with actor for client/api_client tokens
    changeset =
      if type in [:client, :api_client] do
        actor = Map.get(attrs, :actor) || actor_fixture(account: account)
        Ecto.Changeset.put_assoc(changeset, :actor, actor)
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
    attrs
    |> Enum.into(%{})
    |> infrastructure_token_secrets()
    |> then(&struct!(Domain.RelayToken, &1))
    |> Domain.Repo.insert!()
  end

  @doc """
  Generate a gateway token using Domain.GatewayToken schema.
  """
  def gateway_token_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    account = Map.get(attrs, :account) || account_fixture()
    site = Map.get(attrs, :site) || site_fixture(account: account)

    attrs
    |> Map.put(:account_id, account.id)
    |> Map.put(:site_id, site.id)
    |> infrastructure_token_secrets()
    |> then(&struct!(Domain.GatewayToken, &1))
    |> Domain.Repo.insert!()
  end

  defp infrastructure_token_secrets(attrs) do
    attrs =
      attrs
      |> Map.put_new_lazy(:secret_nonce, &generate_secret_nonce/0)
      |> Map.put_new_lazy(:secret_fragment, &generate_secret_fragment/0)
      |> Map.put_new_lazy(:secret_salt, &generate_salt/0)

    Map.put_new_lazy(attrs, :secret_hash, fn ->
      compute_secret_hash(attrs.secret_nonce, attrs.secret_fragment, attrs.secret_salt)
    end)
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
    encode_infrastructure_token(token, "relay", nil)
  end

  @doc """
  Encode a gateway token for use in authentication.
  """
  def encode_gateway_token(token) do
    encode_infrastructure_token(token, "gateway", token.account_id)
  end

  defp encode_infrastructure_token(token, type, account_id) do
    config = Domain.Config.fetch_env!(:domain, Domain.Tokens)
    key_base = Keyword.fetch!(config, :key_base)
    salt = Keyword.fetch!(config, :salt) <> type
    body = {account_id, token.id, token.secret_fragment}

    token.secret_nonce <> "." <> Plug.Crypto.sign(key_base, salt, body)
  end

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
