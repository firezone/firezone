defmodule Domain.Clients do
  use Supervisor
  alias Domain.{Repo, Auth, Validator}
  alias Domain.{Users}
  alias Domain.Clients.{Client, Authorizer}

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    children = [
      Domain.Clients.Presence
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def count do
    Client.Query.all()
    |> Repo.aggregate(:count)
  end

  def count_by_user_id(user_id) do
    Client.Query.by_user_id(user_id)
    |> Repo.aggregate(:count)
  end

  def fetch_client_by_id(id, %Auth.Subject{} = subject) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_clients_permission(),
         Authorizer.manage_own_clients_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions),
         true <- Validator.valid_uuid?(id) do
      Client.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch()
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def fetch_client_by_id!(id, opts \\ []) do
    {preload, _opts} = Keyword.pop(opts, :preload, [])

    Client.Query.by_id(id)
    |> Repo.one!()
    |> Repo.preload(preload)
  end

  def list_clients(%Auth.Subject{} = subject) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_clients_permission(),
         Authorizer.manage_own_clients_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions) do
      Client.Query.all()
      |> Authorizer.for_subject(subject)
      |> Repo.list()
    end
  end

  def list_clients_for_user(%Users.User{} = user, %Auth.Subject{} = subject) do
    list_clients_by_user_id(user.id, subject)
  end

  def list_clients_by_user_id(user_id, %Auth.Subject{} = subject) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_clients_permission(),
         Authorizer.manage_own_clients_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions),
         true <- Validator.valid_uuid?(user_id) do
      Client.Query.by_user_id(user_id)
      |> Authorizer.for_subject(subject)
      |> Repo.list()
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def change_client(%Client{} = client, attrs \\ %{}) do
    Client.Changeset.update_changeset(client, attrs)
  end

  def upsert_client(attrs \\ %{}, %Auth.Subject{actor: {:user, %Users.User{} = user}} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_own_clients_permission()) do
      changeset = Client.Changeset.upsert_changeset(user, subject.context, attrs)

      Ecto.Multi.new()
      |> Ecto.Multi.insert(:client, changeset,
        conflict_target: Client.Changeset.upsert_conflict_target(),
        on_conflict: Client.Changeset.upsert_on_conflict(),
        returning: true
      )
      |> resolve_address_multi(:ipv4)
      |> resolve_address_multi(:ipv6)
      |> Ecto.Multi.update(:client_with_address, fn
        %{client: %Client{} = client, ipv4: ipv4, ipv6: ipv6} ->
          Client.Changeset.finalize_upsert_changeset(client, ipv4, ipv6)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{client_with_address: client}} -> {:ok, client}
        {:error, :client, changeset, _effects_so_far} -> {:error, changeset}
      end
    end
  end

  defp resolve_address_multi(multi, type) do
    Ecto.Multi.run(multi, type, fn _repo, %{client: %Client{} = client} ->
      if address = Map.get(client, type) do
        {:ok, address}
      else
        {:ok, Domain.Network.fetch_next_available_address!(type)}
      end
    end)
  end

  def update_client(%Client{} = client, attrs, %Auth.Subject{} = subject) do
    with :ok <- authorize_user_client_management(client.user_id, subject) do
      Client.Query.by_id(client.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(with: &Client.Changeset.update_changeset(&1, attrs))
    end
  end

  def delete_client(%Client{} = client, %Auth.Subject{} = subject) do
    with :ok <- authorize_user_client_management(client.user_id, subject) do
      Client.Query.by_id(client.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(with: &Client.Changeset.delete_changeset/1)
    end
  end

  def authorize_user_client_management(%Users.User{} = user, %Auth.Subject{} = subject) do
    authorize_user_client_management(user.id, subject)
  end

  def authorize_user_client_management(user_id, %Auth.Subject{} = subject) do
    required_permissions =
      case subject.actor do
        {:user, %{id: ^user_id}} ->
          Authorizer.manage_own_clients_permission()

        _other ->
          Authorizer.manage_clients_permission()
      end

    Auth.ensure_has_permissions(subject, required_permissions)
  end
end
