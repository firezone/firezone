defmodule Domain.Auth.DirectorySync.WorkOS do
  def fetch_directory(%Domain.Auth.Provider{} = provider) do
    case provider.adapter_config do
      %{"workos_org" => %{"id" => org_id}} ->
        fetch_directory(org_id)

      _ ->
        {:ok, nil}
    end
  end

  def fetch_directory(workos_org_id) do
    client = fetch_workos_client()

    case WorkOS.DirectorySync.list_directories(client, %{organization_id: workos_org_id}) do
      {:ok, %WorkOS.List{data: [directory]}} ->
        {:ok, directory}

      {:ok, %WorkOS.List{data: []}} ->
        {:ok, nil}

      {:error, %WorkOS.Error{message: _msg} = error} ->
        {:error, error}

      _ ->
        {:error, "Something went wrong fetching directory"}
    end
  end

  def create_organization(provider, subject) do
    client = fetch_workos_client()

    with {:ok, workos_org} <-
           WorkOS.Organizations.create_organization(client, %{name: provider.id}),
         {:ok, _} <-
           Domain.Auth.update_provider(
             provider,
             %{adapter_config: %{"workos_org" => Map.from_struct(workos_org)}},
             subject
           ) do
      {:ok, workos_org}
    else
      {:error, %WorkOS.Error{message: msg}} ->
        {:error, msg}

      _ ->
        {:error, "Something went wrong creating organization"}
    end
  end

  def create_portal_link(provider, return_url, subject) do
    with {:ok, workos_org} <- fetch_or_create_workos_org(provider, subject),
         {:ok, workos_portal_link} <-
           WorkOS.Portal.generate_link(%{
             organization: workos_org.id,
             intent: "dsync",
             success_url: return_url
           }) do
      {:ok, workos_portal_link}
    else
      {:error, %WorkOS.Error{message: msg}} ->
        {:error, msg}

      _ ->
        {:error, "Something went wrong creating portal link"}
    end
  end

  defp fetch_or_create_workos_org(provider, subject) do
    client = fetch_workos_client()

    case provider.adapter_config do
      %{"workos_org" => %{"id" => workos_org_id}} ->
        WorkOS.Organizations.get_organization(client, workos_org_id)

      %{} ->
        __MODULE__.create_organization(provider, subject)
    end
  end

  defp fetch_workos_client do
    Domain.Config.fetch_env!(:workos, WorkOS.Client)
    |> WorkOS.Client.new()
  end
end
