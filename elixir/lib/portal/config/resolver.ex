defmodule Portal.Config.Resolver do
  @type source :: {:env, atom()} | :default

  @spec resolve(
          key :: atom(),
          env_var_to_configurations :: map(),
          opts :: Keyword.t()
        ) ::
          {:ok, {source :: source(), value :: term()}} | :error
  def resolve(key, env_var_to_configurations, opts) do
    with :error <- resolve_process_env_value(key),
         :error <- resolve_env_value(env_var_to_configurations, key),
         :error <- resolve_default_value(opts) do
      :error
    end
  end

  if Mix.env() == :test do
    defp resolve_process_env_value(key) do
      pdict_key = {__MODULE__, key}

      case fetch_process_env(pdict_key) do
        {:ok, {:env, value}} ->
          {:ok, {{:env, key}, value}}

        :error ->
          :error
      end
    end

    def fetch_process_env(pdict_key) do
      with :error <- fetch_process_value(pdict_key),
           :error <- fetch_process_value(Process.get(:last_caller_pid), pdict_key),
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
        {:ok, value}
      else
        _other -> :error
      end
    end

    defp get_last_pid_from_pdict_list(stack) do
      if values = Process.get(stack) do
        List.last(values)
      end
    end
  else
    defp resolve_process_env_value(_key), do: :error
  end

  defp resolve_env_value(env_var_to_configurations, key) do
    with :error <- fetch_env(env_var_to_configurations, key) do
      :error
    else
      {:ok, {_source, nil}} -> :error
      {:ok, source_and_value} -> {:ok, source_and_value}
    end
  end

  defp fetch_env(env_var_to_configurations, key) do
    key = env_key(key)

    case Map.fetch(env_var_to_configurations, key) do
      {:ok, value} -> {:ok, {{:env, key}, value}}
      :error -> :error
    end
  end

  def env_key(key) do
    key
    |> to_string()
    |> String.upcase()
  end

  defp resolve_default_value(opts) do
    with {:ok, value} <- Keyword.fetch(opts, :default) do
      {:ok, {:default, maybe_apply_default_value_callback(value)}}
    end
  end

  defp maybe_apply_default_value_callback(cb) when is_function(cb, 0), do: cb.()
  defp maybe_apply_default_value_callback(value), do: value
end
