defmodule FzHttp.Config do
  @moduledoc """
  This module provides set of helper functions that are useful when reading application runtime configuration overrides
  in test environment.
  """

  if Mix.env() != :test do
    defdelegate put_env(app, key, value), to: Application
    defdelegate fetch_env!(app, key), to: Application
  else
    def put_env(app \\ :fz_http, key, value) do
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
    def fetch_env!(app, key) do
      application_env = Application.fetch_env!(app, key)

      pdict_key = key_function(app, key)
      
      with :error <- fetch_process_value(pdict_key),
           :error <- fetch_process_value(get_last_pid_from_pdict_list(:"$ancestors"), pdict_key),
           :error <- fetch_process_value(get_last_pid_from_pdict_list(:"$callers"), pdict_key) do
        application_env
      else
        {:ok, override} -> override
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
  end

  # String.to_atom/1 is only used in test env
  defp key_function(app, key), do: String.to_atom("#{app}-#{key}")
end
