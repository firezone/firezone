defmodule FzHttp.Config.Resolver do
  def resolve_value(key, env_configurations, db_configurations, opts) do
    with :error <- resolve_env_value(env_configurations, key, opts),
         :error <- resolve_db_value(db_configurations, key),
         :error <- resolve_default_value(opts) do
      {:not_found, nil}
    else
      {:ok, {source, value}} -> {source, value}
    end
  end

  defp resolve_env_value(env_configurations, key, opts) do
    legacy_keys =
      opts
      |> Keyword.get(:legacy_keys, [])
      |> Enum.flat_map(fn
        {:env, key, _removed_at} -> [key]
        _other -> []
      end)

    Enum.find_value([key] ++ legacy_keys, :error, fn key ->
      key =
        key
        |> to_string()
        |> String.upcase()

      case Map.fetch(env_configurations, key) do
        {:ok, value} -> {:ok, {{:env, key}, value}}
        :error -> nil
      end
    end)
  end

  defp resolve_db_value(db_configurations, key) do
    case Map.fetch(db_configurations, key) do
      {:ok, value} -> {:ok, {{:db, key}, value}}
      :error -> :error
    end
  end

  defp resolve_default_value(opts) do
    with {:ok, value} <- Keyword.fetch(opts, :default) do
      # TODO: replace patterns
      value = String.replace(value, "${external_url.host}", "localhost")
      {:ok, {:default, value}}
    end
  end
end
