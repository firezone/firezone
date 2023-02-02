defmodule FzHttp.Config.Resolver do
  alias FzHttp.Config.Errors

  def resolve(key, env_configurations, db_configurations, opts) do
    with :error <- resolve_app_env_value(key),
         :error <- resolve_env_value(env_configurations, key, opts),
         :error <- resolve_db_value(db_configurations, key),
         :error <- resolve_default_value(opts) do
      :error
    end
  end

  defp resolve_app_env_value(key) do
    with {:ok, value} <- fetch_application_env(:fz_http, key) do
      {:ok, {{:app_env, key}, value}}
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

  if Mix.env() != :test do
    defdelegate fetch_application_env(app, key), to: Application
  else
    def put_env_override(app \\ :fz_http, key, value) do
      Process.put(key_function(app, key), value)
      :ok
    end

    @doc """
    Attempts to override application env configuration from one of 3 sources (in this exact order):
      * takes it from process dictionary of a current process;
      * takes it from process dictionary of a last process in $ancestors stack.
      * takes it from process dictionary of a last process in $callers stack;

    This function is especially useful when some options (eg. request endpoint) needs to be overridden
    in test environment (eg. to send those requests to Bypass).
    """
    def fetch_application_env(app, key) do
      pdict_key = key_function(app, key)

      with :error <- fetch_process_value(pdict_key),
           :error <- fetch_process_value(get_last_pid_from_pdict_list(:"$ancestors"), pdict_key),
           :error <- fetch_process_value(get_last_pid_from_pdict_list(:"$callers"), pdict_key) do
        Application.fetch_env(app, key)
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
      case :erlang.process_info(pid, :dictionary) do
        {:dictionary, pdict} ->
          Keyword.fetch(pdict, key)

        _other ->
          :error
      end
    end

    defp get_last_pid_from_pdict_list(stack) do
      if values = Process.get(stack) do
        List.last(values)
      end
    end

    defp key_function(app, key), do: String.to_atom("#{app}-#{key}")
  end
end
