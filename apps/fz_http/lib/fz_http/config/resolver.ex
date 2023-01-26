defmodule FzHttp.Config.Resolver do
  alias FzHttp.Config.Errors

  def resolve(key, env_configurations, db_configurations, opts) do
    with :error <- resolve_env_value(env_configurations, key, opts),
         :error <- resolve_db_value(db_configurations, key),
         :error <- resolve_default_value(opts) do
      {:not_found, nil}
    else
      {:ok, {source, value}} -> {source, value}
    end
  end

  defp resolve_env_value(env_configurations, key, opts) do
    legacy_keys = Keyword.get(opts, :legacy_keys, [])

    with :error <- fetch_env(env_configurations, key),
         :error <- fetch_legacy_env(env_configurations, key, legacy_keys) do
      :error
    end
  end

  defp fetch_env(env_configurations, key) do
    key = env_key(key)

    case Map.fetch(env_configurations, key) do
      {:ok, value} -> {:ok, {{:env, key}, value}}
      :error -> :error
    end
  end

  def env_key(key) do
    key
    |> to_string()
    |> String.upcase()
  end

  defp fetch_legacy_env(env_configurations, key, legacy_keys) do
    Enum.find_value(legacy_keys, :error, fn {:env, legacy_key, removed_at} ->
      case fetch_env(env_configurations, key) do
        {:ok, value} ->
          maybe_warn_on_legacy_key(key, legacy_key, removed_at)
          {:ok, value}

        :error ->
          nil
      end
    end)
  end

  defp maybe_warn_on_legacy_key(_key, _legacy_key, nil) do
    :ok
  end

  defp maybe_warn_on_legacy_key(key, legacy_key, removed_at) do
    Errors.legacy_key_used(key, legacy_key, removed_at)
  end

  defp resolve_db_value(db_configurations, key) do
    case Map.fetch(db_configurations, key) do
      :error -> :error
      {:ok, nil} -> :error
      {:ok, value} -> {:ok, {{:db, key}, value}}
    end
  end

  defp resolve_default_value(opts) do
    with {:ok, value} <- Keyword.fetch(opts, :default) do
      {:ok, {:default, value}}
    end
  end
end
