defmodule Domain.Auth.Adapters.JumpCloud.APIClient do
  use Supervisor

  def start_link(_init_arg) do
    Supervisor.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = []

    Supervisor.init(children, strategy: :one_for_one)
  end

  def list_users(nil) do
    {:error, "No directory to fetch users from"}
  end

  def list_users(directory) do
    list_all_users(directory.id, :start)
  end

  defp list_all_users(directory_id, after_record, acc \\ []) do
    list_users_params =
      %{directory: directory_id}
      |> add_after_param(after_record)
      |> Map.put(:limit, 100)

    client = fetch_workos_client()

    case WorkOS.DirectorySync.list_users(client, list_users_params) do
      {:ok, %WorkOS.List{data: users, list_metadata: %{"after" => nil}}} ->
        {:ok, List.flatten(Enum.reverse([users | acc]))}

      {:ok, %WorkOS.List{data: users, list_metadata: %{"after" => last_record}}} ->
        list_all_users(directory_id, last_record, [users | acc])

      {:error, %WorkOS.Error{} = error} ->
        {:error, error}

      {:error, msg} ->
        {:error, msg}
    end
  end

  def list_groups(nil) do
    {:error, "No directory to fetch groups from"}
  end

  def list_groups(directory) do
    list_all_groups(directory.id, :start)
  end

  defp list_all_groups(directory_id, after_record, acc \\ []) do
    list_groups_params =
      %{directory: directory_id}
      |> add_after_param(after_record)
      |> Map.put(:limit, 100)

    client = fetch_workos_client()

    case WorkOS.DirectorySync.list_groups(client, list_groups_params) do
      {:ok, %WorkOS.List{data: groups, list_metadata: %{"after" => nil}}} ->
        {:ok, List.flatten(Enum.reverse([groups | acc]))}

      {:ok, %WorkOS.List{data: groups, list_metadata: %{"after" => last_record}}} ->
        list_all_groups(directory_id, last_record, [groups | acc])

      {:error, %WorkOS.Error{} = error} ->
        {:error, error}

      {:error, msg} ->
        {:error, msg}
    end
  end

  defp add_after_param(params, value) do
    case value do
      :start -> params
      nil -> params
      _ -> Map.put(params, :after, value)
    end
  end

  defp fetch_workos_client do
    Domain.Config.fetch_env!(:workos, WorkOS.Client)
    |> WorkOS.Client.new()
  end
end
