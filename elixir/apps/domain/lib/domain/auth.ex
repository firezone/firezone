defmodule Domain.Auth do
  import Ecto.Changeset
  require Ecto.Query
  alias Domain.Token
  alias Domain.Auth.{Subject, Context}
  alias __MODULE__.DB
  require Logger

  # Tokens

  def create_service_account_token(
        %Domain.Actor{type: :service_account, account_id: account_id} = actor,
        attrs,
        %Subject{account: %{id: account_id}} = subject
      ) do
    attrs =
      Map.merge(attrs, %{
        "type" => :client,
        "secret_fragment" => Domain.Crypto.random_token(32, encoder: :hex32),
        "account_id" => actor.account_id,
        "actor_id" => actor.id
      })

    with {:ok, token} <- create_token(attrs, subject) do
      {:ok, encode_fragment!(token)}
    end
  end

  def create_api_client_token(
        %Domain.Actor{type: :api_client, account_id: account_id} = actor,
        attrs,
        %Subject{account: %{id: account_id}} = subject
      ) do
    attrs =
      Map.merge(attrs, %{
        "type" => :api_client,
        "secret_fragment" => Domain.Crypto.random_token(32, encoder: :hex32),
        "account_id" => actor.account_id,
        "actor_id" => actor.id
      })

    with {:ok, token} <- create_token(attrs, subject) do
      {:ok, encode_fragment!(token)}
    end
  end

  # Token encoding/decoding

  @doc """
  Encodes a token fragment for transmission.

  The token is encoded as a tuple of {account_id, token_id, secret_fragment}
  which is then signed using Plug.Crypto to ensure it can't be tampered with.
  """
  def encode_fragment!(%Token{secret_fragment: fragment, type: type} = token)
      when not is_nil(fragment) do
    body = {token.account_id, token.id, fragment}
    config = fetch_config!()
    key_base = Keyword.fetch!(config, :key_base)
    salt = Keyword.fetch!(config, :salt)
    "." <> Plug.Crypto.sign(key_base, salt <> to_string(type), body)
  end

  # Token Management

  def create_token(attrs) do
    changeset = create_token_changeset(%Token{}, attrs, nil)
    DB.insert_token(changeset)
  end

  def create_token(attrs, %Subject{} = subject) do
    changeset = create_token_changeset(%Token{}, attrs, subject)
    DB.insert_token(changeset)
  end

  defp create_token_changeset(token, attrs, subject) do
    changeset =
      token
      |> cast(
        attrs,
        ~w[name account_id actor_id site_id auth_provider_id secret_fragment secret_nonce remaining_attempts expires_at type]a
      )
      |> validate_required(~w[type]a)

    changeset =
      if subject do
        changeset
        |> put_change(:account_id, subject.account.id)
      else
        changeset
      end

    changeset
    |> put_change(:secret_salt, Domain.Crypto.random_token(16))
    |> validate_format(:secret_nonce, ~r/^[^\.]{0,128}$/)
    |> validate_required(:secret_fragment)
    |> Domain.Changeset.put_hash(:secret_fragment, :sha3_256,
      with_nonce: :secret_nonce,
      with_salt: :secret_salt,
      to: :secret_hash
    )
    |> delete_change(:secret_nonce)
    |> Domain.Changeset.validate_datetime(:expires_at, greater_than: DateTime.utc_now())
    |> validate_required(~w[secret_salt secret_hash]a)
    |> validate_required_assocs()
  end

  defp validate_required_assocs(changeset) do
    case fetch_field(changeset, :type) do
      {_data_or_changes, :browser} ->
        changeset
        |> validate_required(:actor_id)
        |> validate_required(:expires_at)

      {_data_or_changes, :client} ->
        changeset
        |> validate_required(:actor_id)

      {_data_or_changes, :api_client} ->
        changeset
        |> validate_required(:actor_id)

      {_data_or_changes, :relay} ->
        changeset

      {_data_or_changes, :site} ->
        changeset
        |> validate_required(:site_id)

      {_data_or_changes, :email} ->
        changeset
        |> validate_required(:actor_id)
        |> validate_required(:expires_at)
        |> validate_required(:remaining_attempts)

      _ ->
        changeset
    end
  end

  def use_token(encoded_token, %Context{} = context)
      when is_binary(encoded_token) do
    with {:ok, {nonce, account_id, id, fragment}} <-
           decode_token_with_context(encoded_token, context),
         {:ok, token} <- DB.fetch_token_for_use(id, account_id, context.type),
         :ok <- verify_secret_hash(token, nonce, fragment),
         changeset = use_token_changeset(token, context),
         {:ok, token} <- DB.update_token(changeset) do
      {:ok, token}
    else
      _ -> {:error, :invalid_or_expired_token}
    end
  end

  defp decode_token_with_context(encoded_token, %Context{} = context) do
    config = fetch_config!()
    key_base = Keyword.fetch!(config, :key_base)
    base_salt = Keyword.fetch!(config, :salt)
    salt = base_salt <> to_string(context.type)
    legacy_salt = legacy_token_salt(context.type, base_salt)

    with {:error, _} <- try_decode(encoded_token, key_base, salt),
         {:error, _} <- try_decode(encoded_token, key_base, legacy_salt) do
      {:error, :invalid_token}
    end
  end

  defp try_decode(_encoded_token, _key_base, nil), do: {:error, :no_salt}

  defp try_decode(encoded_token, key_base, salt) do
    with [nonce, encoded_fragment] <- String.split(encoded_token, ".", parts: 2),
         {:ok, {account_id, id, fragment}} <-
           Plug.Crypto.verify(key_base, salt, encoded_fragment, max_age: :infinity) do
      {:ok, {nonce, account_id, id, fragment}}
    else
      _ -> {:error, :invalid_token}
    end
  end

  # Maps new token types to their legacy equivalents for backwards compatibility
  defp legacy_token_salt(:site, base_salt), do: base_salt <> "gateway_group"
  defp legacy_token_salt(:relay, base_salt), do: base_salt <> "relay_group"
  defp legacy_token_salt(_type, _base_salt), do: nil

  defp use_token_changeset(%Token{} = token, %Context{} = context) do
    token
    |> change()
    |> put_change(:last_seen_user_agent, context.user_agent)
    |> put_change(:last_seen_remote_ip, %Postgrex.INET{address: context.remote_ip})
    |> put_change(:last_seen_remote_ip_location_region, context.remote_ip_location_region)
    |> put_change(:last_seen_remote_ip_location_city, context.remote_ip_location_city)
    |> put_change(:last_seen_remote_ip_location_lat, context.remote_ip_location_lat)
    |> put_change(:last_seen_remote_ip_location_lon, context.remote_ip_location_lon)
    |> put_change(:last_seen_at, DateTime.utc_now())
    |> validate_required(~w[last_seen_user_agent last_seen_remote_ip]a)
  end

  defp verify_secret_hash(token, nonce, fragment) do
    expected_hash = token_secret_hash(token, nonce, fragment)

    if Plug.Crypto.secure_compare(expected_hash, token.secret_hash) do
      :ok
    else
      :error
    end
  end

  defp token_secret_hash(token, nonce, fragment) do
    Domain.Crypto.hash(:sha3_256, nonce <> fragment <> token.secret_salt)
  end

  def socket_id(id) when is_binary(id) do
    "tokens:#{id}"
  end

  # Authentication

  def authenticate(encoded_token, %Context{} = context)
      when is_binary(encoded_token) do
    with {:ok, token} <- use_token(encoded_token, context),
         {:ok, subject} <- build_subject(token, context) do
      {:ok, subject}
    else
      {:error, :invalid_or_expired_token} ->
        {:error, :unauthorized}

      {:error, :not_found} ->
        {:error, :unauthorized}
    end
  end

  def build_subject(%Token{type: type} = token, %Context{} = context)
      when type in [:browser, :client, :api_client] do
    account = DB.get_account_by_id!(token.account_id)

    with {:ok, actor} <- DB.fetch_active_actor_by_id(token.actor_id) do
      {:ok,
       %Subject{
         actor: actor,
         account: account,
         expires_at: token.expires_at,
         context: context,
         token_id: token.id,
         auth_provider_id: token.auth_provider_id
       }}
    end
  end

  defp fetch_config! do
    Domain.Config.fetch_env!(:domain, Domain.Tokens)
  end

  defmodule DB do
    import Ecto.Query
    alias Domain.Safe
    alias Domain.Account
    alias Domain.Actor
    alias Domain.Token

    def get_account_by_id!(id) do
      from(a in Account, where: a.id == ^id)
      |> Safe.unscoped()
      |> Safe.one!()
    end

    def fetch_active_actor_by_id(id) do
      from(a in Actor, where: a.id == ^id, where: is_nil(a.disabled_at))
      |> Safe.unscoped()
      |> Safe.one()
      |> case do
        nil -> {:error, :not_found}
        actor -> {:ok, actor}
      end
    end

    def insert_token(changeset) do
      changeset
      |> Safe.unscoped()
      |> Safe.insert()
    end

    def update_token(changeset) do
      # Relay tokens don't have account_id, so we can't use the composite primary key
      # for updates. Instead, use update_all with the token id.
      token = changeset.data

      if is_nil(token.account_id) do
        changes = changeset.changes

        from(t in Token, where: t.id == ^token.id)
        |> Safe.unscoped()
        |> Safe.update_all(set: Enum.to_list(changes))

        {:ok, struct(token, changes)}
      else
        changeset
        |> Safe.unscoped()
        |> Safe.update()
      end
    end

    def fetch_token_for_use(id, account_id, context_type) do
      query =
        from(tokens in Token, as: :tokens)
        |> where(
          [tokens: tokens],
          tokens.expires_at > ^DateTime.utc_now() or is_nil(tokens.expires_at)
        )
        |> where([tokens: tokens], tokens.id == ^id)
        |> where([tokens: tokens], tokens.type == ^context_type)

      # Relay tokens don't have account scope
      query =
        if context_type == :relay do
          query
        else
          where(query, [tokens: tokens], tokens.account_id == ^account_id)
        end

      case query |> Safe.unscoped() |> Safe.one() do
        nil ->
          {:error, :not_found}

        token ->
          # Update last_seen_at
          from(t in Token, where: t.id == ^token.id)
          |> Safe.unscoped()
          |> Safe.update_all(set: [last_seen_at: DateTime.utc_now()])

          {:ok, token}
      end
    end
  end
end
