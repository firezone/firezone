defmodule Portal.Repo.Preloader do
  @moduledoc """
  This module implements a preload overriding mechanism for the `Portal.Repo`,
  it accepts the same syntax as `Ecto.Repo.preload/2` and returns results with
  preloads and list of not overridden preloads that needs to be executed by Ecto.
  """
  alias Portal.Repo.Query

  def preload(schema, preload, query_module) do
    preloads_funs = Query.get_preloads_funs(query_module)
    handle_preloads(schema, preload, preloads_funs)
  end

  # preload on a list of schemas, eg. on `Repo.list(..., preload: :identity)`
  defp handle_preloads(results, preloads, preloads_funs) when is_list(results) do
    {results, ecto_preloads, []} =
      {results, [], preloads}
      |> pop_and_handle_preload(preloads_funs)

    {results, ecto_preloads}
  end

  # preload on a schema, eg. on `Repo.fetch(..., preload: :identity)`
  defp handle_preloads(result, preloads, preloads_funs) do
    {[result], ecto_preloads, []} =
      {[result], [], preloads}
      |> pop_and_handle_preload(preloads_funs)

    {result, ecto_preloads}
  end

  # there is no results so we remove all preloads
  defp pop_and_handle_preload({[], ecto_preloads, _preloads}, _preloads_funs) do
    {[], ecto_preloads, []}
  end

  # when there are no more preloads to process we return the results
  # and preloads that will be executed by `Ecto.Repo.preload/2`
  defp pop_and_handle_preload({results, ecto_preloads, []}, _preloads_funs) do
    {results, ecto_preloads, []}
  end

  # for every preload we try to execute it and see if it has an override
  defp pop_and_handle_preload({results, ecto_preloads, [preload | preloads]}, preloads_funs) do
    {results, ecto_preloads, preloads}
    |> handle_preload(preload, preloads_funs)
    |> pop_and_handle_preload(preloads_funs)
  end

  # preload can also be a single atom: `preload: :foo`
  defp pop_and_handle_preload({results, ecto_preloads, preload}, preloads_funs) do
    {results, ecto_preloads, []}
    |> handle_preload(preload, preloads_funs)
    |> pop_and_handle_preload(preloads_funs)
  end

  # preload is nested, eg: preload: [actor: :identities]
  defp handle_preload(
         {results, ecto_preloads, preloads},
         {preload, nested_preloads},
         preloads_funs
       ) do
    case get_preload_cb(preloads_funs, preload) do
      nil ->
        {
          results,
          [{preload, nested_preloads}] ++ ecto_preloads,
          preloads
        }

      {preload_fun, []} ->
        {results, ecto_preloads_to_prepend} =
          apply_or_postpone_preload(results, preload, preload_fun)

        {
          results,
          [{preload, nested_preloads}] ++ ecto_preloads_to_prepend ++ ecto_preloads,
          preloads
        }

      {nil, nested_preload_funs} ->
        results = Portal.Repo.preload(results, preload)

        {results, nested_ecto_preloads} =
          handle_nested_preloads(results, preload, nested_preloads, nested_preload_funs)

        {
          results,
          [{preload, nested_ecto_preloads}] ++ ecto_preloads,
          preloads
        }

      # if we got a query and also nested preloads - we have to execute it right away to proceed
      {%Ecto.Query{} = query, nested_preload_funs} ->
        results = Portal.Repo.preload(results, [{preload, query}])

        {results, nested_ecto_preloads} =
          handle_nested_preloads(results, preload, nested_preloads, nested_preload_funs)

        {
          results,
          [{preload, nested_ecto_preloads}] ++ ecto_preloads,
          preloads
        }

      {preload_fun, nested_preload_funs} ->
        {results, ecto_preloads_to_prepend} =
          apply_or_postpone_preload(results, preload, preload_fun)

        {results, nested_ecto_preloads} =
          handle_nested_preloads(results, preload, nested_preloads, nested_preload_funs)

        {
          results,
          ecto_preloads_to_prepend ++ [{preload, nested_ecto_preloads}] ++ ecto_preloads,
          preloads
        }
    end
  end

  # preload is an atom
  defp handle_preload(
         {results, ecto_preloads, preloads},
         preload,
         preloads_funs
       ) do
    case get_preload_cb(preloads_funs, preload) do
      nil ->
        {results, [preload] ++ ecto_preloads, preloads}

      {preload_fun, _nested_preload_funs} ->
        {results, ecto_preloads_to_prepend} =
          apply_or_postpone_preload(results, preload, preload_fun)

        {results, ecto_preloads_to_prepend ++ ecto_preloads, preloads}
    end
  end

  defp handle_nested_preloads(results, preload, nested_preloads, nested_preload_funs) do
    {results, nested_ecto_preloads} =
      Enum.reduce(results, {[], []}, fn result, {results_acc, ecto_preloads_acc} ->
        {nested_result, ecto_preloads_to_prepend} =
          result
          |> Map.fetch!(preload)
          |> handle_preloads(nested_preloads, nested_preload_funs)

        result = Map.put(result, preload, nested_result)

        {[result] ++ results_acc, ecto_preloads_to_prepend ++ ecto_preloads_acc}
      end)

    {Enum.reverse(results), nested_ecto_preloads}
  end

  # if it's a function that accepts an argument - it's used to map the results
  defp apply_or_postpone_preload(results, _preload, preload_fun)
       when is_function(preload_fun, 1) do
    {preload_fun.(results), []}
  end

  # TODO: we can have 1-arity function that returns a query for join-preload

  # if its a query - it's used to define a queryable for the Ecto
  defp apply_or_postpone_preload(results, preload, %Ecto.Query{} = query) do
    {results, [{preload, query}]}
  end

  defp get_preload_cb(preload_funs, preload) do
    case Keyword.get(preload_funs, preload) do
      {preload_fun, nested_preload_funs} ->
        {preload_fun, nested_preload_funs}

      nil ->
        nil

      nested_preload_funs when is_list(nested_preload_funs) ->
        {nil, nested_preload_funs}

      preload_fun ->
        {preload_fun, []}
    end
  end
end
