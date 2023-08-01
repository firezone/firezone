defmodule Domain.Relays do
  use Supervisor
  alias Domain.{Repo, Auth, Validator}
  alias Domain.Resources
  alias Domain.Relays.{Authorizer, Relay, Group, Token, Presence}

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    children = [
      Presence
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def fetch_group_by_id(id, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_relays_permission()),
         true <- Validator.valid_uuid?(id) do
      Group.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch()
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def list_groups(%Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_relays_permission()) do
      Group.Query.all()
      |> Authorizer.for_subject(subject)
      |> Repo.list()
    end
  end

  def new_group(attrs \\ %{}) do
    change_group(%Group{}, attrs)
  end

  def create_group(attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_relays_permission()) do
      subject.account
      |> Group.Changeset.create_changeset(attrs, subject)
      |> Repo.insert()
    end
  end

  def create_global_group(attrs) do
    Group.Changeset.create_changeset(attrs)
    |> Repo.insert()
  end

  def change_group(%Group{} = group, attrs \\ %{}) do
    group
    |> Repo.preload(:account)
    |> Group.Changeset.update_changeset(attrs)
  end

  def update_group(group, attrs \\ %{}, subject)

  def update_group(%Group{account_id: nil}, _attrs, %Auth.Subject{}) do
    {:error, :unauthorized}
  end

  def update_group(%Group{} = group, attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_relays_permission()) do
      group
      |> Repo.preload(:account)
      |> Group.Changeset.update_changeset(attrs, subject)
      |> Repo.update()
    end
  end

  def delete_group(%Group{account_id: nil}, %Auth.Subject{}) do
    {:error, :unauthorized}
  end

  def delete_group(%Group{} = group, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_relays_permission()) do
      Group.Query.by_id(group.id)
      |> Authorizer.for_subject(subject)
      |> Group.Query.by_account_id(subject.account.id)
      |> Repo.fetch_and_update(
        with: fn group ->
          :ok =
            Token.Query.by_group_id(group.id)
            |> Repo.all()
            |> Enum.each(fn token ->
              Token.Changeset.delete_changeset(token)
              |> Repo.update!()
            end)

          group
          |> Group.Changeset.delete_changeset()
        end
      )
    end
  end

  def use_token_by_id_and_secret(id, secret) do
    if Validator.valid_uuid?(id) do
      Token.Query.by_id(id)
      |> Repo.fetch_and_update(
        with: fn token ->
          if Domain.Crypto.equal?(secret, token.hash) do
            Token.Changeset.use_changeset(token)
          else
            :not_found
          end
        end
      )
    else
      {:error, :not_found}
    end
  end

  def fetch_relay_by_id(id, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_relays_permission()),
         true <- Validator.valid_uuid?(id) do
      Relay.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch()
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def fetch_relay_by_id!(id, opts \\ []) do
    {preload, _opts} = Keyword.pop(opts, :preload, [])

    Relay.Query.by_id(id)
    |> Repo.one!()
    |> Repo.preload(preload)
  end

  def list_relays(%Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_relays_permission()) do
      Relay.Query.all()
      |> Authorizer.for_subject(subject)
      |> Repo.list()
    end
  end

  def list_connected_relays_for_resource(%Resources.Resource{} = resource) do
    connected_relays =
      Map.merge(
        Presence.list("relays:"),
        Presence.list("relays:#{resource.account_id}")
      )

    relays =
      connected_relays
      |> Map.keys()
      |> Relay.Query.by_ids()
      |> Relay.Query.by_account_id(resource.account_id)
      |> Repo.all()
      |> Enum.map(fn relay ->
        %{metas: [%{secret: stamp_secret}]} = Map.get(connected_relays, relay.id)
        %{relay | stamp_secret: stamp_secret}
      end)

    {:ok, relays}
  end

  def generate_username_and_password(%Relay{stamp_secret: stamp_secret}, %DateTime{} = expires_at)
      when is_binary(stamp_secret) do
    expires_at = DateTime.to_unix(expires_at, :second)
    salt = Domain.Crypto.rand_string()
    password = generate_hash(expires_at, stamp_secret, salt)
    %{username: "#{expires_at}:#{salt}", password: password, expires_at: expires_at}
  end

  defp generate_hash(expires_at, stamp_secret, salt) do
    :crypto.hash(:sha256, "#{expires_at}:#{stamp_secret}:#{salt}")
    |> Base.encode64(padding: false)
  end

  def upsert_relay(%Token{} = token, attrs) do
    changeset = Relay.Changeset.upsert_changeset(token, attrs)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:relay, changeset,
      conflict_target: Relay.Changeset.upsert_conflict_target(),
      on_conflict: Relay.Changeset.upsert_on_conflict(),
      returning: true
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{relay: relay}} -> {:ok, relay}
      {:error, :relay, changeset, _effects_so_far} -> {:error, changeset}
    end
  end

  def delete_relay(%Relay{} = relay, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_relays_permission()) do
      Relay.Query.by_id(relay.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(with: &Relay.Changeset.delete_changeset/1)
    end
  end

  def encode_token!(%Token{value: value} = token) when not is_nil(value) do
    body = {token.id, token.value}
    config = fetch_config!()
    key_base = Keyword.fetch!(config, :key_base)
    salt = Keyword.fetch!(config, :salt)
    Plug.Crypto.sign(key_base, salt, body)
  end

  def authorize_relay(encrypted_secret) do
    config = fetch_config!()
    key_base = Keyword.fetch!(config, :key_base)
    salt = Keyword.fetch!(config, :salt)

    with {:ok, {id, secret}} <-
           Plug.Crypto.verify(key_base, salt, encrypted_secret, max_age: :infinity),
         {:ok, token} <- use_token_by_id_and_secret(id, secret) do
      {:ok, token}
    else
      {:error, :invalid} -> {:error, :invalid_token}
      {:error, :not_found} -> {:error, :invalid_token}
    end
  end

  def connect_relay(%Relay{} = relay, secret) do
    {:ok, _} =
      Presence.track(self(), "relays:#{relay.account_id}", relay.id, %{
        online_at: System.system_time(:second),
        secret: secret
      })

    :ok
  end

  defp fetch_config! do
    Domain.Config.fetch_env!(:domain, __MODULE__)
  end
end
