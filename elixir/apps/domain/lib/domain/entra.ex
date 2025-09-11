defmodule Domain.Entra do
  alias Domain.{Auth, Entra, Entra.Authorizer, Repo}

  def fetch_directory_by_id(id, %Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_directories_permission()),
         true <- Repo.valid_uuid?(id) do
      Entra.Directory.Query.all()
      |> Entra.Directory.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Entra.Directory.Query, opts)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def fetch_directory_for_sync(id) do
    Entra.Directory.Query.not_disabled()
    |> Entra.Directory.Query.by_id(id)
    |> Entra.Directory.Query.with_preloads_for_sync()
    |> Repo.fetch(Entra.Directory.Query)
  end

  def stream_directories_for_sync do
    Entra.Directory.Query.not_disabled()
    |> Entra.Directory.Query.for_sync()
    |> Repo.stream()
  end

  def list_group_inclusions(%Entra.Directory{} = directory, %Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_directories_permission()) do
      Entra.GroupInclusion.Query.all()
      |> Entra.GroupInclusion.Query.by_directory_id(directory.id)
      |> Authorizer.for_subject(subject)
      |> Repo.list(Entra.GroupInclusion.Query, opts)
    end
  end

  def create_directory_from_auth_provider(%Auth.Provider{} = provider, %Auth.Subject{} = subject) do
    uri = provider.adapter_config["discovery_document_uri"]
    [_, tenant_id] = Regex.run(~r/login\.microsoftonline\.com\/([a-f0-9\-]{36})/, uri)

    # TODO: Populate tenant_id, client_id, client_secret from new setup wizard
    attrs = %{
      account_id: provider.account_id,
      auth_provider_id: provider.id,
      client_id: provider.adapter_config["client_id"],
      client_secret: provider.adapter_config["client_secret"],
      tenant_id: tenant_id
    }

    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_directories_permission()) do
      %Entra.Directory{}
      |> Entra.Directory.Changeset.create(attrs)
      |> Repo.insert()
    end
  end

  def update_directory(%Entra.Directory{} = directory, attrs) do
    directory
    |> Entra.Directory.Changeset.update(attrs)
    |> Repo.update()
  end
end
