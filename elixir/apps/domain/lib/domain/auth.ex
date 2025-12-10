defmodule Domain.Auth do
  import Ecto.Changeset
  import Ecto.Query
  import Domain.Changeset
  alias Domain.Token
  alias Domain.OneTimePasscode
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

  # Relay Tokens

  def create_relay_token do
    {secret_fragment, secret_nonce, secret_salt, secret_hash} = generate_token_secrets()

    %Domain.RelayToken{
      secret_fragment: secret_fragment,
      secret_nonce: secret_nonce,
      secret_salt: secret_salt,
      secret_hash: secret_hash
    }
    |> DB.insert_relay_token()
  end

  # Gateway Tokens

  def create_gateway_token(%Domain.Site{} = site, %Subject{} = subject) do
    {secret_fragment, secret_nonce, secret_salt, secret_hash} = generate_token_secrets()

    %Domain.GatewayToken{
      account_id: site.account_id,
      site_id: site.id,
      secret_fragment: secret_fragment,
      secret_nonce: secret_nonce,
      secret_salt: secret_salt,
      secret_hash: secret_hash
    }
    |> DB.insert_gateway_token(subject)
  end

  defp generate_token_secrets do
    secret_fragment = Domain.Crypto.random_token(32, encoder: :hex32)
    secret_nonce = Domain.Crypto.random_token(8, encoder: :url_encode64)
    secret_salt = Domain.Crypto.random_token(16)
    secret_hash = Domain.Crypto.hash(:sha3_256, secret_nonce <> secret_fragment <> secret_salt)
    {secret_fragment, secret_nonce, secret_salt, secret_hash}
  end

  # One-Time Passcodes

  @otp_expiration_seconds 15 * 60

  def create_one_time_passcode(%Domain.Account{} = account, %Domain.Actor{} = actor) do
    code = Domain.Crypto.random_token(5, encoder: :user_friendly)
    code_hash = Domain.Crypto.hash(:argon2, code)
    expires_at = DateTime.utc_now() |> DateTime.add(@otp_expiration_seconds, :second)

    # Delete existing passcodes for this actor first
    :ok = DB.delete_one_time_passcodes_for_actor(account, actor)

    %OneTimePasscode{
      account_id: account.id,
      actor_id: actor.id,
      code_hash: code_hash,
      code: code,
      expires_at: expires_at
    }
    |> DB.insert_one_time_passcode()
  end

  def verify_one_time_passcode(account_id, passcode_id, entered_code) do
    case DB.fetch_one_time_passcode(account_id, passcode_id) do
      {:ok, passcode} ->
        if Domain.Crypto.equal?(:argon2, entered_code, passcode.code_hash) do
          :ok = DB.delete_one_time_passcode(passcode)
          {:ok, passcode}
        else
          {:error, :invalid_code}
        end

      {:error, :not_found} ->
        # Perform dummy verification to prevent timing attacks
        Domain.Crypto.equal?(:argon2, nil, nil)
        {:error, :invalid_code}
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

  def encode_fragment!(%Domain.RelayToken{} = token) do
    encode_infrastructure_token(token, "relay", nil)
  end

  def encode_fragment!(%Domain.GatewayToken{} = token) do
    encode_infrastructure_token(token, "gateway", token.account_id)
  end

  defp encode_infrastructure_token(token, type, account_id) do
    body = {account_id, token.id, token.secret_fragment}
    config = fetch_config!()
    key_base = Keyword.fetch!(config, :key_base)
    salt = Keyword.fetch!(config, :salt)
    token.secret_nonce <> "." <> Plug.Crypto.sign(key_base, salt <> type, body)
  end

  def verify_relay_token(encoded_token) when is_binary(encoded_token) do
    verify_infrastructure_token(encoded_token, "relay", "relay_group", &DB.fetch_relay_token/1)
  end

  def verify_gateway_token(encoded_token) when is_binary(encoded_token) do
    verify_infrastructure_token(
      encoded_token,
      "gateway",
      "gateway_group",
      &DB.fetch_gateway_token/2
    )
  end

  defp verify_infrastructure_token(encoded_token, current_salt, legacy_salt, fetch_fn) do
    config = fetch_config!()
    key_base = Keyword.fetch!(config, :key_base)
    base_salt = Keyword.fetch!(config, :salt)

    with [nonce, signed] <- String.split(encoded_token, ".", parts: 2),
         {:ok, {account_id, id, fragment}} <-
           decode_infrastructure_token(signed, key_base, base_salt, current_salt, legacy_salt),
         {:ok, token} <- apply_fetch(fetch_fn, account_id, id),
         :ok <- verify_token_hash(token, nonce, fragment) do
      {:ok, token}
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp apply_fetch(fetch_fn, _account_id, id) when is_function(fetch_fn, 1), do: fetch_fn.(id)

  defp apply_fetch(fetch_fn, account_id, id) when is_function(fetch_fn, 2),
    do: fetch_fn.(account_id, id)

  defp decode_infrastructure_token(signed, key_base, base_salt, current_salt, legacy_salt) do
    case Plug.Crypto.verify(key_base, base_salt <> current_salt, signed, max_age: :infinity) do
      {:ok, _} = result ->
        result

      {:error, _} ->
        Plug.Crypto.verify(key_base, base_salt <> legacy_salt, signed, max_age: :infinity)
    end
  end

  defp verify_token_hash(token, nonce, fragment) do
    expected_hash = Domain.Crypto.hash(:sha3_256, nonce <> fragment <> token.secret_salt)

    if Plug.Crypto.secure_compare(expected_hash, token.secret_hash) do
      :ok
    else
      :error
    end
  end

  # Token Management

  def create_token(attrs, subject \\ nil) do
    changeset = create_token_changeset(%Token{}, attrs, subject)
    DB.insert_token(changeset)
  end

  defp create_token_changeset(token, attrs, subject) do
    changeset =
      token
      |> cast(
        attrs,
        ~w[name account_id actor_id auth_provider_id secret_fragment secret_nonce expires_at type]a
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
    |> put_hash(:secret_fragment, :sha3_256,
      with_nonce: :secret_nonce,
      with_salt: :secret_salt,
      to: :secret_hash
    )
    |> delete_change(:secret_nonce)
    |> validate_datetime(:expires_at, greater_than: DateTime.utc_now())
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

      {_data_or_changes, :email} ->
        changeset
        |> validate_required(:actor_id)
        |> validate_required(:expires_at)

      _ ->
        changeset
    end
  end

  def fetch_token(account_id, token_id, context_type) do
    DB.fetch_token_for_use(account_id, token_id, context_type)
  end

  def use_token(encoded_token, %Context{} = context)
      when is_binary(encoded_token) do
    with {:ok, {nonce, account_id, id, fragment}} <-
           decode_token_with_context(encoded_token, context),
         {:ok, token} <- DB.fetch_token_for_use(account_id, id, context.type),
         :ok <- verify_secret_hash(token, nonce, fragment),
         changeset = use_token_changeset(token, context),
         {:ok, token} <- DB.update_token(changeset) do
      {:ok, token}
    else
      error ->
        trace = Process.info(self(), :current_stacktrace)
        Logger.info("Token use failed", stacktrace: trace, error: error)

        {:error, :invalid_token}
    end
  end

  defp decode_token_with_context(encoded_token, %Context{} = context) do
    config = fetch_config!()
    key_base = Keyword.fetch!(config, :key_base)
    base_salt = Keyword.fetch!(config, :salt)
    salt = base_salt <> to_string(context.type)

    with {:error, _} <- try_decode(encoded_token, key_base, salt) do
      {:error, :invalid_token}
    end
  end

  defp try_decode(encoded_token, key_base, salt) do
    with [nonce, encoded_fragment] <- String.split(encoded_token, ".", parts: 2),
         {:ok, {account_id, id, fragment}} <-
           Plug.Crypto.verify(key_base, salt, encoded_fragment, max_age: :infinity) do
      {:ok, {nonce, account_id, id, fragment}}
    end
  end

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
      error ->
        trace = Process.info(self(), :current_stacktrace)
        Logger.info("Authentication failed", stacktrace: trace, error: error)

        {:error, :invalid_token}
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
    alias Domain.OneTimePasscode

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

    def insert_relay_token(relay_token) do
      relay_token
      |> Safe.unscoped()
      |> Safe.insert()
    end

    def fetch_relay_token(id) do
      from(rt in Domain.RelayToken, where: rt.id == ^id)
      |> Safe.unscoped()
      |> Safe.one()
      |> case do
        nil -> {:error, :not_found}
        relay_token -> {:ok, relay_token}
      end
    end

    def insert_gateway_token(gateway_token, subject) do
      gateway_token
      |> Safe.scoped(subject)
      |> Safe.insert()
    end

    def fetch_gateway_token(account_id, id) do
      from(gt in Domain.GatewayToken,
        where: gt.account_id == ^account_id,
        where: gt.id == ^id
      )
      |> Safe.unscoped()
      |> Safe.one()
      |> case do
        nil -> {:error, :not_found}
        gateway_token -> {:ok, gateway_token}
      end
    end

    def update_token(changeset) do
      changeset
      |> Safe.unscoped()
      |> Safe.update()
    end

    def fetch_token_for_use(account_id, token_id, context_type) do
      from(tokens in Token, as: :tokens)
      |> where(
        [tokens: tokens],
        tokens.expires_at > ^DateTime.utc_now() or is_nil(tokens.expires_at)
      )
      |> where([tokens: tokens], tokens.id == ^token_id)
      |> where([tokens: tokens], tokens.type == ^context_type)
      |> where([tokens: tokens], tokens.account_id == ^account_id)
      |> update([tokens: tokens], set: [last_seen_at: ^DateTime.utc_now()])
      |> select([tokens: tokens], tokens)
      |> Safe.unscoped()
      |> Safe.update_all([])
      |> case do
        {1, [token]} -> {:ok, token}
        {0, []} -> {:error, :not_found}
      end
    end

    # One-Time Passcode functions

    def insert_one_time_passcode(passcode) do
      passcode
      |> Safe.unscoped()
      |> Safe.insert()
    end

    def fetch_one_time_passcode(account_id, id) do
      from(otp in OneTimePasscode,
        where: otp.account_id == ^account_id,
        where: otp.id == ^id,
        where: otp.expires_at > ^DateTime.utc_now()
      )
      |> Safe.unscoped()
      |> Safe.one()
      |> case do
        nil -> {:error, :not_found}
        otp -> {:ok, otp}
      end
    end

    def delete_one_time_passcodes_for_actor(account, actor) do
      from(otp in OneTimePasscode,
        where: otp.account_id == ^account.id,
        where: otp.actor_id == ^actor.id
      )
      |> Safe.unscoped()
      |> Safe.delete_all()

      :ok
    end

    def delete_one_time_passcode(passcode) do
      from(otp in OneTimePasscode,
        where: otp.account_id == ^passcode.account_id,
        where: otp.id == ^passcode.id
      )
      |> Safe.unscoped()
      |> Safe.delete_all()

      :ok
    end
  end
end
