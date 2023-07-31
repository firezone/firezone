defmodule Domain.Gateways do
  use Supervisor
  alias Domain.{Repo, Auth, Validator}
  alias Domain.Resources
  alias Domain.Gateways.{Authorizer, Gateway, Group, Token, Presence}

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
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_gateways_permission()),
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
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_gateways_permission()) do
      Group.Query.all()
      |> Authorizer.for_subject(subject)
      |> Repo.list()
    end
  end

  def new_group(attrs \\ %{}) do
    change_group(%Group{}, attrs)
  end

  def create_group(attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_gateways_permission()) do
      subject.account
      |> Group.Changeset.create_changeset(attrs, subject)
      |> Repo.insert()
    end
  end

  def change_group(%Group{} = group, attrs \\ %{}) do
    group
    |> Repo.preload(:account)
    |> Group.Changeset.update_changeset(attrs)
  end

  def update_group(%Group{} = group, attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_gateways_permission()) do
      group
      |> Repo.preload(:account)
      |> Group.Changeset.update_changeset(attrs)
      |> Repo.update()
    end
  end

  def delete_group(%Group{} = group, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_gateways_permission()) do
      Group.Query.by_id(group.id)
      |> Authorizer.for_subject(subject)
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

  def fetch_gateway_by_id(id, %Auth.Subject{} = subject, opts \\ []) do
    {preload, _opts} = Keyword.pop(opts, :preload, [])

    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_gateways_permission()),
         true <- Validator.valid_uuid?(id) do
      Gateway.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch()
      |> case do
        {:ok, gateway} -> {:ok, Repo.preload(gateway, preload)}
        {:error, reason} -> {:error, reason}
      end
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def fetch_gateway_by_id!(id, opts \\ []) do
    {preload, _opts} = Keyword.pop(opts, :preload, [])

    Gateway.Query.by_id(id)
    |> Repo.one!()
    |> Repo.preload(preload)
  end

  def list_gateways(%Auth.Subject{} = subject, opts \\ []) do
    {preload, _opts} = Keyword.pop(opts, :preload, [])

    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_gateways_permission()) do
      {:ok, gateways} =
        Gateway.Query.all()
        |> Authorizer.for_subject(subject)
        |> Repo.list()

      {:ok, Repo.preload(gateways, preload)}
    end
  end

  def list_connected_gateways_for_resource(%Resources.Resource{} = resource) do
    connected_gateways = Presence.list("gateways:#{resource.account_id}")

    gateways =
      connected_gateways
      |> Map.keys()
      # XXX: This will create a pretty large query to send to Postgres,
      # we probably want to load connected resources once when gateway connects,
      # and persist them in the memory not to query DB every time with a
      # `WHERE ... IN (...)`.
      |> Gateway.Query.by_ids()
      |> Gateway.Query.by_account_id(resource.account_id)
      |> Gateway.Query.by_resource_id(resource.id)
      |> Repo.all()

    {:ok, gateways}
  end

  def change_gateway(%Gateway{} = gateway, attrs \\ %{}) do
    Gateway.Changeset.update_changeset(gateway, attrs)
  end

  def upsert_gateway(%Token{} = token, attrs) do
    changeset = Gateway.Changeset.upsert_changeset(token, attrs)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:gateway, changeset,
      conflict_target: Gateway.Changeset.upsert_conflict_target(),
      on_conflict: Gateway.Changeset.upsert_on_conflict(),
      returning: true
    )
    |> resolve_address_multi(:ipv4)
    |> resolve_address_multi(:ipv6)
    |> Ecto.Multi.update(:gateway_with_address, fn
      %{gateway: %Gateway{} = gateway, ipv4: ipv4, ipv6: ipv6} ->
        Gateway.Changeset.finalize_upsert_changeset(gateway, ipv4, ipv6)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{gateway_with_address: gateway}} -> {:ok, gateway}
      {:error, :gateway, changeset, _effects_so_far} -> {:error, changeset}
    end
  end

  defp resolve_address_multi(multi, type) do
    Ecto.Multi.run(multi, type, fn _repo, %{gateway: %Gateway{} = gateway} ->
      if address = Map.get(gateway, type) do
        {:ok, address}
      else
        {:ok, Domain.Network.fetch_next_available_address!(gateway.account_id, type)}
      end
    end)
  end

  def update_gateway(%Gateway{} = gateway, attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_gateways_permission()) do
      Gateway.Query.by_id(gateway.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(with: &Gateway.Changeset.update_changeset(&1, attrs))
    end
  end

  def delete_gateway(%Gateway{} = gateway, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_gateways_permission()) do
      Gateway.Query.by_id(gateway.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(with: &Gateway.Changeset.delete_changeset/1)
    end
  end

  def encode_token!(%Token{value: value} = token) when not is_nil(value) do
    body = {token.id, token.value}
    config = fetch_config!()
    key_base = Keyword.fetch!(config, :key_base)
    salt = Keyword.fetch!(config, :salt)
    Plug.Crypto.sign(key_base, salt, body)
  end

  def authorize_gateway(encrypted_secret) do
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

  def connect_gateway(%Gateway{} = gateway) do
    {:ok, _} =
      Presence.track(self(), "gateways:#{gateway.account_id}", gateway.id, %{
        online_at: System.system_time(:second)
      })

    :ok
  end

  def fetch_gateway_config!(%Gateway{} = _gateway) do
    Application.fetch_env!(:domain, __MODULE__)
  end

  defp fetch_config! do
    Domain.Config.fetch_env!(:domain, __MODULE__)
  end
end
