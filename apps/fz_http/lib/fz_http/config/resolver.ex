defmodule FzHttp.Config.Resolver do
  alias FzHttp.Config.Errors

  @type source :: {:env, atom()} | {:db, atom()} | :default

  @spec resolve(
          key :: atom(),
          env_configurations :: map(),
          db_configurations :: map(),
          opts :: [{:legacy_keys, [FzHttp.Config.Definition.legacy_key()]}]
        ) ::
          {:ok, {source :: source(), value :: term()}} | :error
  def resolve(key, env_configurations, db_configurations, opts) do
    with :error <- resolve_process_env_value(key),
         :error <- resolve_env_value(env_configurations, key, opts),
         :error <- resolve_db_value(db_configurations, key),
         :error <- resolve_default_value(opts) do
      :error
    end
  end

  defp resolve_process_env_value(key) do
    pdict_key = {__MODULE__, key}

    case fetch_process_env(pdict_key) do
      {:ok, {:env, value}} ->
        {:ok, {{:env, env_key(key)}, value}}

      :error ->
        :error
    end
  end

  if Mix.env() == :test do
    def fetch_process_env(pdict_key) do
      with :error <- fetch_process_value(pdict_key),
           :error <- fetch_process_value(get_last_pid_from_pdict_list(:"$ancestors"), pdict_key),
           :error <- fetch_process_value(get_last_pid_from_pdict_list(:"$callers"), pdict_key) do
        :error
      end
    end

    defp fetch_process_value(key) do
      case Process.get(key) do
        nil -> :error
        value -> {:ok, value}
      end
    end

    defp fetch_process_value(nil, _key) do
      :error
    end

    defp fetch_process_value(atom, key) when is_atom(atom) do
      atom
      |> Process.whereis()
      |> fetch_process_value(key)
    end

    defp fetch_process_value(pid, key) do
      with {:dictionary, pdict} <- :erlang.process_info(pid, :dictionary),
           {^key, value} <- List.keyfind(pdict, key, 0) do
        value
      else
        _other ->
          :error
      end
    end

    defp get_last_pid_from_pdict_list(stack) do
      if values = Process.get(stack) do
        List.last(values)
      end
    end
  else
    def fetch_process_env(_pdict_key), do: :error
  end

  defp resolve_env_value(env_configurations, key, opts) do
    legacy_keys = Keyword.get(opts, :legacy_keys, [])

    with :error <- fetch_env(env_configurations, key),
         :error <- fetch_legacy_env(env_configurations, key, legacy_keys) do
      :error
    else
      {:ok, {_source, nil}} -> :error
      {:ok, source_and_value} -> {:ok, source_and_value}
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
      case fetch_env(env_configurations, legacy_key) do
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
      {:ok, {:default, maybe_apply_default_value_callback(value)}}
    end
  end

  defp maybe_apply_default_value_callback(cb) when is_function(cb, 0), do: cb.()
  defp maybe_apply_default_value_callback(value), do: value
end
