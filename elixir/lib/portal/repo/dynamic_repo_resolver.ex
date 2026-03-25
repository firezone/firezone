defmodule Portal.Repo.DynamicRepoResolver do
  @moduledoc """
  Walks the process hierarchy (`$callers` then `$ancestors`) to find and
  inherit a parent's dynamic repo setting.

  Used by `Portal.Repo.get_dynamic_repo/0` and `Portal.Repo.Replica.get_dynamic_repo/0`
  so that child processes (channels, tasks, GenServers) automatically route
  queries to the same pool as their parent.
  """

  @spec inherit(module()) :: module()
  def inherit(repo_module) do
    callers = Process.get(:"$callers", [])
    ancestors = Process.get(:"$ancestors", [])

    find_in_hierarchy(repo_module, callers ++ ancestors)
  end

  defp find_in_hierarchy(repo_module, []) do
    repo_module
  end

  defp find_in_hierarchy(repo_module, [pid | rest]) when is_pid(pid) do
    case :erlang.process_info(pid, :dictionary) do
      {:dictionary, dict} ->
        case List.keyfind(dict, {repo_module, :dynamic_repo}, 0) do
          {_, repo} -> repo
          nil -> find_in_hierarchy(repo_module, rest)
        end

      :undefined ->
        find_in_hierarchy(repo_module, rest)
    end
  end

  defp find_in_hierarchy(repo_module, [name | rest]) when is_atom(name) do
    case Process.whereis(name) do
      nil -> find_in_hierarchy(repo_module, rest)
      pid -> find_in_hierarchy(repo_module, [pid | rest])
    end
  end
end
