defmodule Portal.Authentication do
  import Ecto.Changeset
  import Ecto.Query
  import Portal.Changeset
  alias Portal.ClientToken
  alias Portal.OneTimePasscode
  alias Portal.PortalSession
  alias Portal.Authentication.Context
  alias Portal.Authentication.Credential
  alias Portal.Authentication.Subject
  alias __MODULE__.Database
  require Logger

  # Client Tokens

  # GUI client token - called from auth controllers
  def create_gui_client_token(attrs) do
    changeset =
      %ClientToken{}
      |> cast(attrs, ~w[secret_nonce account_id actor_id auth_provider_id expires_at]a)
      |> validate_required([:account_id, :actor_id, :auth_provider_id, :expires_at])
      |> validate_length(:secret_nonce, max: 128)
      |> validate_format(:secret_nonce, ~r/^[^.]*$/, message: "cannot contain periods")

    nonce = get_change(changeset, :secret_nonce) || ""
    {secret_fragment, secret_salt, secret_hash} = generate_token_secrets(nonce)

    changeset
    |> put_change(:secret_fragment, secret_fragment)
    |> put_change(:secret_salt, secret_salt)
    |> put_change(:secret_hash, secret_hash)
    |> Database.insert_token()
  end

  # Headless client token - used with service accounts
  def create_headless_client_token(
        %Portal.Actor{type: :service_account, account_id: account_id} = actor,
        attrs,
        %Subject{account: %{id: account_id}} = subject
      ) do
    {secret_fragment, secret_salt, secret_hash} = generate_token_secrets()

    %ClientToken{
      account_id: actor.account_id,
      actor_id: actor.id,
      secret_nonce: "",
      secret_fragment: secret_fragment,
      secret_salt: secret_salt,
      secret_hash: secret_hash
    }
    |> cast(attrs, [:expires_at])
    |> validate_required([:expires_at])
    |> validate_datetime(:expires_at, greater_than: DateTime.utc_now())
    |> Database.insert_token(subject)
  end

  # API Tokens

  def create_api_token(
        %Portal.Actor{type: :api_client, account_id: account_id} = actor,
        attrs,
        %Subject{account: %{id: account_id}} = subject
      ) do
    {secret_fragment, secret_salt, secret_hash} = generate_token_secrets()

    %Portal.APIToken{
      account_id: actor.account_id,
      actor_id: actor.id,
      secret_fragment: secret_fragment,
      secret_salt: secret_salt,
      secret_hash: secret_hash
    }
    |> cast(attrs, [:name, :expires_at])
    |> validate_required([:expires_at])
    |> validate_datetime(:expires_at, greater_than: DateTime.utc_now())
    |> Database.insert_api_token(subject)
    |> case do
      {:ok, token} -> {:ok, encode_fragment!(token)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  # Relay Tokens

  def create_relay_token do
    {secret_fragment, secret_salt, secret_hash} = generate_token_secrets()

    %Portal.RelayToken{
      secret_fragment: secret_fragment,
      secret_salt: secret_salt,
      secret_hash: secret_hash
    }
    |> Database.insert_relay_token()
  end

  # Gateway Tokens

  def create_gateway_token(%Portal.Site{} = site, %Subject{} = subject) do
    {secret_fragment, secret_salt, secret_hash} = generate_token_secrets()

    %Portal.GatewayToken{
      account_id: site.account_id,
      site_id: site.id,
      secret_fragment: secret_fragment,
      secret_salt: secret_salt,
      secret_hash: secret_hash
    }
    |> Database.insert_gateway_token(subject)
  end

  defp generate_token_secrets(nonce \\ "") do
    secret_fragment = Portal.Crypto.random_token(32, encoder: :hex32)
    secret_salt = Portal.Crypto.random_token(16)
    secret_hash = Portal.Crypto.hash(:sha3_256, nonce <> secret_fragment <> secret_salt)
    {secret_fragment, secret_salt, secret_hash}
  end

  # One-Time Passcodes

  @otp_expiration_seconds 15 * 60

  def create_one_time_passcode(%Portal.Account{} = account, %Portal.Actor{} = actor) do
    code = Portal.Crypto.random_token(5, encoder: :user_friendly)
    code_hash = Portal.Crypto.hash(:argon2, code)
    expires_at = DateTime.utc_now() |> DateTime.add(@otp_expiration_seconds, :second)

    # Delete existing passcodes for this actor first
    :ok = Database.delete_one_time_passcodes_for_actor(account, actor)

    %OneTimePasscode{
      account_id: account.id,
      actor_id: actor.id,
      code_hash: code_hash,
      code: code,
      expires_at: expires_at
    }
    |> Database.insert_one_time_passcode()
  end

  def verify_one_time_passcode(account_id, actor_id, passcode_id, entered_code) do
    case Database.fetch_one_time_passcode(account_id, actor_id, passcode_id) do
      {:ok, passcode} ->
        if Portal.Crypto.equal?(:argon2, entered_code, passcode.code_hash) do
          :ok = Database.delete_one_time_passcode(passcode)
          {:ok, passcode}
        else
          {:error, :invalid_code}
        end

      {:error, :not_found} ->
        # Perform dummy verification to prevent timing attacks
        Portal.Crypto.equal?(:argon2, nil, nil)
        {:error, :invalid_code}
    end
  end

  # Portal Sessions

  def create_portal_session(
        %Portal.Actor{type: :account_admin_user, account_id: account_id, id: actor_id},
        auth_provider_id,
        %Context{} = context,
        expires_at
      ) do
    %PortalSession{
      account_id: account_id,
      actor_id: actor_id,
      auth_provider_id: auth_provider_id,
      user_agent: context.user_agent,
      remote_ip: %Postgrex.INET{address: context.remote_ip},
      remote_ip_location_region: context.remote_ip_location_region,
      remote_ip_location_city: context.remote_ip_location_city,
      remote_ip_location_lat: context.remote_ip_location_lat,
      remote_ip_location_lon: context.remote_ip_location_lon,
      expires_at: expires_at
    }
    |> Database.insert_portal_session()
  end

  def fetch_portal_session(account_id, session_id) do
    Database.fetch_portal_session(account_id, session_id)
  end

  def delete_portal_session(%PortalSession{} = session) do
    Database.delete_portal_session(session)
  end

  # Token encoding/decoding

  @doc """
  Encodes a token fragment for transmission.

  The token is encoded as a tuple of {account_id, token_id, secret_fragment}
  which is then signed using Plug.Crypto to ensure it can't be tampered with.
  """
  def encode_fragment!(%ClientToken{} = token),
    do: encode_token(token.account_id, token.id, token.secret_fragment, "client")

  def encode_fragment!(%Portal.RelayToken{} = token),
    do: encode_token(nil, token.id, token.secret_fragment, "relay")

  def encode_fragment!(%Portal.GatewayToken{} = token),
    do: encode_token(token.account_id, token.id, token.secret_fragment, "gateway")

  def encode_fragment!(%Portal.APIToken{} = token),
    do: encode_token(token.account_id, token.id, token.secret_fragment, "api_client")

  defp encode_token(account_id, id, fragment, type) do
    body = {account_id, id, fragment}
    config = fetch_config!()
    key_base = Keyword.fetch!(config, :key_base)
    salt = Keyword.fetch!(config, :salt)
    "." <> Plug.Crypto.sign(key_base, salt <> type, body)
  end

  def verify_relay_token(encoded_token) when is_binary(encoded_token) do
    verify_infrastructure_token(
      encoded_token,
      "relay",
      "relay_group",
      &Database.fetch_relay_token/1
    )
  end

  def verify_gateway_token(encoded_token) when is_binary(encoded_token) do
    verify_infrastructure_token(
      encoded_token,
      "gateway",
      "gateway_group",
      &Database.fetch_gateway_token/2
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
         :ok <- verify_secret_hash(token, nonce, fragment) do
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

  def fetch_token(account_id, token_id, %Context{} = context) do
    Database.fetch_token_for_use(account_id, token_id, context)
  end

  def use_token(encoded_token, %Context{} = context)
      when is_binary(encoded_token) do
    with {:ok, {nonce, account_id, id, fragment}} <-
           decode_token_with_context(encoded_token, context),
         {:ok, token} <- Database.fetch_token_for_use(account_id, id, context),
         :ok <- verify_secret_hash(token, nonce, fragment) do
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

  defp verify_secret_hash(token, nonce, fragment) do
    expected_hash = Portal.Crypto.hash(:sha3_256, nonce <> fragment <> token.secret_salt)

    if Plug.Crypto.secure_compare(expected_hash, token.secret_hash) do
      :ok
    else
      :error
    end
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

  def build_subject(%ClientToken{} = token, %Context{} = context) do
    credential = %Credential{
      type: :client_token,
      id: token.id,
      auth_provider_id: token.auth_provider_id
    }

    do_build_subject(token, context, credential)
  end

  def build_subject(%Portal.APIToken{} = token, %Context{} = context) do
    credential = %Credential{type: :api_token, id: token.id}
    do_build_subject(token, context, credential)
  end

  def build_subject(%PortalSession{} = session, %Context{} = context) do
    credential = %Credential{
      type: :portal_session,
      id: session.id,
      auth_provider_id: session.auth_provider_id
    }

    do_build_subject(session, context, credential)
  end

  defp do_build_subject(token_or_session, context, credential) do
    account = Database.get_account_by_id!(token_or_session.account_id)

    with {:ok, actor} <- Database.fetch_active_actor_by_id(token_or_session.actor_id) do
      {:ok,
       %Subject{
         actor: actor,
         account: account,
         expires_at: token_or_session.expires_at,
         context: context,
         credential: credential
       }}
    end
  end

  defp fetch_config! do
    Portal.Config.fetch_env!(:portal, Portal.Tokens)
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{Authorization, Repo}
    alias Portal.Account
    alias Portal.Actor
    alias Portal.ClientToken
    alias Portal.OneTimePasscode

    def get_account_by_id!(id) do
      from(a in Account, where: a.id == ^id)
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      |> Repo.one!()
    end

    def fetch_active_actor_by_id(id) do
      from(a in Actor, where: a.id == ^id, where: is_nil(a.disabled_at))
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      |> Repo.one()
      |> case do
        nil -> {:error, :not_found}
        actor -> {:ok, actor}
      end
    end

    # Client
    def insert_token(changeset) do
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      Repo.insert(changeset)
    end

    # Service Account
    def insert_token(changeset, subject) do
      Authorization.with_subject(subject, fn ->
        Repo.insert(changeset)
      end)
    end

    def insert_relay_token(relay_token) do
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      Repo.insert(relay_token)
    end

    def fetch_relay_token(id) do
      from(rt in Portal.RelayToken, where: rt.id == ^id)
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      |> Repo.one()
      |> case do
        nil -> {:error, :not_found}
        relay_token -> {:ok, relay_token}
      end
    end

    def insert_gateway_token(gateway_token, subject) do
      Authorization.with_subject(subject, fn ->
        case Authorization.authorize(:insert, Portal.GatewayToken, subject) do
          :ok -> Repo.insert(gateway_token)
          {:error, :unauthorized} -> {:error, :unauthorized}
        end
      end)
    end

    def insert_api_token(changeset, subject) do
      Authorization.with_subject(subject, fn ->
        Repo.insert(changeset)
      end)
    end

    def fetch_gateway_token(account_id, id) do
      from(gt in Portal.GatewayToken,
        where: gt.account_id == ^account_id,
        where: gt.id == ^id
      )
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      |> Repo.one()
      |> case do
        nil -> {:error, :not_found}
        gateway_token -> {:ok, gateway_token}
      end
    end

    def fetch_token_for_use(account_id, token_id, %Portal.Authentication.Context{} = context) do
      now = DateTime.utc_now()
      remote_ip = %Postgrex.INET{address: context.remote_ip}

      schema =
        case context.type do
          :api_client -> Portal.APIToken
          :client -> ClientToken
        end

      from(tokens in schema, as: :tokens)
      |> join(:inner, [tokens: tokens], account in assoc(tokens, :account), as: :account)
      |> join(:inner, [tokens: tokens], actor in assoc(tokens, :actor), as: :actor)
      |> where([tokens: tokens], tokens.expires_at > ^now or is_nil(tokens.expires_at))
      |> where([tokens: tokens], tokens.id == ^token_id)
      |> where([tokens: tokens], tokens.account_id == ^account_id)
      |> where([account: account], is_nil(account.disabled_at))
      |> where([actor: actor], is_nil(actor.disabled_at))
      |> update([tokens: tokens],
        set: [
          last_seen_at: ^now,
          last_seen_user_agent: ^context.user_agent,
          last_seen_remote_ip: ^remote_ip,
          last_seen_remote_ip_location_region: ^context.remote_ip_location_region,
          last_seen_remote_ip_location_city: ^context.remote_ip_location_city,
          last_seen_remote_ip_location_lat: ^context.remote_ip_location_lat,
          last_seen_remote_ip_location_lon: ^context.remote_ip_location_lon
        ]
      )
      |> select([tokens: tokens], tokens)
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      |> Repo.update_all([])
      |> case do
        {1, [token]} -> {:ok, token}
        {0, []} -> {:error, :not_found}
      end
    end

    # One-Time Passcode functions

    def insert_one_time_passcode(passcode) do
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      Repo.insert(passcode)
    end

    def fetch_one_time_passcode(account_id, actor_id, id) do
      from(otp in OneTimePasscode,
        join: a in assoc(otp, :actor),
        where: otp.account_id == ^account_id,
        where: otp.actor_id == ^actor_id,
        where: otp.id == ^id,
        where: otp.expires_at > ^DateTime.utc_now(),
        where: is_nil(a.disabled_at),
        where: a.allow_email_otp_sign_in == true,
        preload: [actor: a]
      )
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      |> Repo.one()
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
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      |> Repo.delete_all()

      :ok
    end

    def delete_one_time_passcode(passcode) do
      from(otp in OneTimePasscode,
        where: otp.account_id == ^passcode.account_id,
        where: otp.id == ^passcode.id
      )
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      |> Repo.delete_all()

      :ok
    end

    # Portal Session functions

    def insert_portal_session(session) do
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      Repo.insert(session)
    end

    def fetch_portal_session(account_id, id) do
      enabled_provider_ids = enabled_auth_provider_ids_subquery()

      from(ps in PortalSession,
        join: a in assoc(ps, :actor),
        where: ps.account_id == ^account_id,
        where: ps.id == ^id,
        where: ps.expires_at > ^DateTime.utc_now(),
        where: is_nil(a.disabled_at),
        where: ps.auth_provider_id in subquery(enabled_provider_ids),
        preload: [actor: a]
      )
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      |> Repo.one()
      |> case do
        nil -> {:error, :not_found}
        session -> {:ok, session}
      end
    end

    defp enabled_auth_provider_ids_subquery do
      provider_modules = [
        Portal.EmailOTP.AuthProvider,
        Portal.Userpass.AuthProvider,
        Portal.Google.AuthProvider,
        Portal.Okta.AuthProvider,
        Portal.Entra.AuthProvider,
        Portal.OIDC.AuthProvider
      ]

      provider_modules
      |> Enum.map(fn module ->
        from(p in module, where: p.is_disabled == false, select: p.id)
      end)
      |> Enum.reduce(&union_all(&2, ^&1))
    end

    def delete_portal_session(session) do
      from(ps in PortalSession,
        where: ps.account_id == ^session.account_id,
        where: ps.id == ^session.id
      )
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      |> Repo.delete_all()

      :ok
    end
  end
end
