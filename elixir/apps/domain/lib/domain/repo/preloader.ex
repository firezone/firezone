defmodule Domain.Repo.Preloader do
  alias Domain.Repo.Query

  def preload(result_or_results, preloads, query_module) do
    preloads_funs = Query.get_preloads_funs(query_module)

    {result_or_results, ecto_preloads, []} =
      {result_or_results, [], preloads}
      |> map_preloads(preloads_funs)

    {result_or_results, ecto_preloads}
  end

  defp map_preloads({result_or_results, ecto_preloads, []}, _preloads_funs) do
    {result_or_results, ecto_preloads, []}
  end

  defp map_preloads({result_or_results, ecto_preloads, [preload | preloads]}, preloads_funs) do
    {result_or_results, ecto_preloads, preloads}
    |> map_preload(preload, preloads_funs)
    |> map_preloads(preloads_funs)
  end

  defp map_preloads({result_or_results, ecto_preloads, preload}, preloads_funs) do
    {result_or_results, ecto_preloads, []}
    |> map_preload(preload, preloads_funs)
    |> map_preloads(preloads_funs)
  end

  defp map_preload({[], ecto_preloads, preloads}, _preload, _preloads_funs) do
    {[], ecto_preloads, preloads}
  end

  defp map_preload({results, ecto_preloads, preloads}, preload, preloads_funs)
       when is_list(results) do
    {preload_fun, _nested_preloads} = get_preload_cb(preloads_funs, preload)

    cond do
      is_function(preload_fun, 1) ->
        results = preload_fun.(results)
        {results, ecto_preloads, preloads}

      is_function(preload_fun, 0) ->
        queryable = preload_fun.()
        {results, [{preload, queryable}] ++ ecto_preloads, preloads}

      is_nil(preload_fun) ->
        {results, [preload] ++ ecto_preloads, preloads}
    end
  end

  defp map_preload({result, ecto_preloads, preloads}, preload, preloads_funs) do
    {preload_fun, _nested_preloads} = get_preload_cb(preloads_funs, preload)

    cond do
      is_function(preload_fun, 1) ->
        [result] = preload_fun.([result])
        {result, ecto_preloads, preloads}

      is_function(preload_fun, 0) ->
        queryable = preload_fun.()
        {result, [{preload, queryable}] ++ ecto_preloads, preloads}

      is_nil(preload_fun) ->
        {result, [preload] ++ ecto_preloads, preloads}
    end
  end

  defp get_preload_cb(preload_funs, preload) do
    case Keyword.get(preload_funs, preload) do
      preload_fun when is_function(preload_fun, 1) ->
        {preload_fun, []}

      {preload_fun, nested_preload_funs} when is_function(preload_fun, 1) ->
        {preload_fun, nested_preload_funs}

      nil ->
        {nil, []}
    end
  end
end
