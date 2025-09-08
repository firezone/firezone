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
    |> Repo.fetch(Entra.Directory.Query, preload: [:auth_provider, :account])
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
end
