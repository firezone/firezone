defmodule Domain.Gateways do
  alias Domain.{Repo, Auth, Validator}
  alias Domain.{Users}
  alias Domain.Gateways.{Authorizer, Gateway, Group, Token}

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

  def create_group(attrs \\ %{}, %Auth.Subject{actor: {:user, %Users.User{}}} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_gateways_permission()) do
      attrs
      |> Group.Changeset.changeset()
      |> Repo.insert()
    end
  end

  def change_group(%Group{} = group, attrs \\ %{}) do
    Group.Changeset.changeset(group, attrs)
  end

  def update_group(
        %Group{} = group,
        attrs \\ %{},
        %Auth.Subject{actor: {:user, %Users.User{}}} = subject
      ) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_gateways_permission()) do
      group
      |> Group.Changeset.changeset(attrs)
      |> Repo.update()
    end
  end

  def delete_group(%Group{} = group, %Auth.Subject{actor: {:user, %Users.User{}}} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_gateways_permission()) do
      Group.Query.by_id(group.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(with: &Group.Changeset.delete_changeset/1)
    end
  end

  def fetch_token_by_id_and_secret(id, secret) do
    queryable = Token.Query.by_id(id)

    with true <- Validator.valid_uuid?(id),
         {:ok, token} <- Repo.fetch(queryable),
         true <- Domain.Crypto.equal?(secret, token.hash) do
      {:ok, token}
    else
      _other -> {:error, :not_found}
    end
  end

  def fetch_gateway_by_id(id, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_gateways_permission()),
         true <- Validator.valid_uuid?(id) do
      Gateway.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch()
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

  def list_gateways(%Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_gateways_permission()) do
      Gateway.Query.all()
      |> Authorizer.for_subject(subject)
      |> Repo.list()
    end
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
        {:ok, Domain.Network.fetch_next_available_address!(type)}
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

  def generate_name(name \\ Domain.NameGenerator.generate()) do
    hash =
      name
      |> :erlang.phash2(2 ** 16)
      |> Integer.to_string(16)
      |> String.pad_leading(4, "0")

    if String.length(name) > 15 do
      String.slice(name, 0..10) <> hash
    else
      name
    end
  end
end
