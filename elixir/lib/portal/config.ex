defmodule Portal.Config do
  alias Portal.Config.{Azure, Definitions, Errors, Fetcher}

  @azure_settings_key {__MODULE__, :azure_settings}

  @doc """
  Returns the settings that configuration keys resolve from, keyed by their
  environment variable names.

  With the `environment` adapter these are the environment variables. With the
  `azure` adapter, the App Configuration store's settings take precedence and
  environment variables fill in any setting the store does not have. The store
  is read once per VM boot.
  """
  def source do
    env = System.get_env()

    case Fetcher.fetch_source_and_config(Definitions, :config_adapter, env) do
      {:ok, _source, :environment} -> env
      {:ok, _source, :azure} -> Map.merge(env, azure_values(azure_settings!(env)))
      {:error, reason} -> Errors.raise_error!(reason)
    end
  end

  @doc false
  # The App Configuration settings read at boot, with their modes. Only
  # Portal.Config.Watcher replaces them, when it applies a live change.
  def azure_settings, do: :persistent_term.get(@azure_settings_key, nil)

  @doc false
  def put_azure_settings(settings), do: :persistent_term.put(@azure_settings_key, settings)

  @doc false
  # Reads the store and, when a cache path is set, keeps a copy of what it read.
  def fetch_azure_settings!(env \\ System.get_env()) do
    endpoints =
      case env_var_to_config!(Definitions, :azure_app_configuration_endpoint, env) do
        [_ | _] = endpoints -> endpoints
        _unset -> raise "AZURE_APP_CONFIGURATION_ENDPOINT must be set when CONFIG_ADAPTER is azure"
      end

    settings =
      Azure.fetch_settings!(endpoints, env_var_to_config(Definitions, :azure_client_id, env))

    if cache_path = env_var_to_config(Definitions, :azure_app_configuration_cache_path, env) do
      write_cache(cache_path, settings)
    end

    settings
  end

  @doc false
  # Boots from the cached copy when the store cannot be read.
  def load_azure_settings!(fetch, cache_path) do
    fetch.()
  rescue
    exception ->
      with path when is_binary(path) <- cache_path,
           {:ok, settings} <- Azure.read_cache(path) do
        IO.puts(:stderr, "App Configuration unavailable, booting from #{path}: " <> Exception.message(exception))
        settings
      else
        _ -> reraise exception, __STACKTRACE__
      end
  end

  defp write_cache(path, settings) do
    Azure.write_cache!(path, settings)
  rescue
    exception ->
      IO.puts(:stderr, "Could not write #{path}: " <> Exception.message(exception))
  end

  defp azure_values(settings), do: Map.new(settings, fn {key, %{value: value}} -> {key, value} end)

  defp azure_settings!(env) do
    case :persistent_term.get(@azure_settings_key, nil) do
      nil ->
        cache_path = env_var_to_config(Definitions, :azure_app_configuration_cache_path, env)
        settings = load_azure_settings!(fn -> fetch_azure_settings!(env) end, cache_path)
        put_azure_settings(settings)
        settings

      settings ->
        settings
    end
  end

  def fetch_resolved_configs!(account_id, keys, opts \\ []) do
    for {key, {_source, value}} <-
          fetch_resolved_configs_with_sources!(account_id, keys, opts),
        into: %{} do
      {key, value}
    end
  end

  def fetch_resolved_configs_with_sources!(_account_id, keys, _opts \\ []) do
    env_var_to_config = source()

    for key <- keys, into: %{} do
      case Fetcher.fetch_source_and_config(Definitions, key, env_var_to_config) do
        {:ok, source, config} ->
          {key, {source, config}}

        {:error, reason} ->
          Errors.raise_error!(reason)
      end
    end
  end

  @doc """
  Similar to `env_var_to_config/2` but raises an error if the configuration is invalid.

  This function does not resolve values from the database because it's intended use is during
  compilation and before application boot (in `config/runtime.exs`).

  If you need to resolve values from the database, use `fetch_config/1` or `fetch_config!/1`.
  """
  def env_var_to_config!(module \\ Definitions, key, env_var_to_config \\ source()) do
    case Fetcher.fetch_source_and_config(module, key, env_var_to_config) do
      {:ok, _source, value} ->
        value

      {:error, reason} ->
        Errors.raise_error!(reason)
    end
  end

  @doc """
  Similar to `env_var_to_config!/3` but returns nil if the configuration is invalid.

  This function does not resolve values from the database because it's intended use is during
  compilation and before application boot (in `config/runtime.exs`).

  If you need to resolve values from the database, use `fetch_config/1` or `fetch_config!/1`.
  """
  def env_var_to_config(module \\ Definitions, key, env_var_to_config \\ source()) do
    case Fetcher.fetch_source_and_config(module, key, env_var_to_config) do
      {:ok, _source, value} ->
        value

      {:error, _reason} ->
        nil
    end
  end

  ## Test helpers

  if Mix.env() != :test do
    defdelegate fetch_env!(app, key), to: Application
    defdelegate get_env(app, key, default \\ nil), to: Application
  else
    def put_env_override(app \\ :portal, key, value) do
      merged_value =
        if Keyword.keyword?(value) do
          base = Application.fetch_env!(app, key)
          Keyword.merge(base, value)
        else
          value
        end

      Process.put(pdict_key_function(app, key), merged_value)
      :ok
    end

    @doc """
    Like `put_env_override/3` but merges nested keyword lists instead of
    replacing them, so overriding one entry of `:req_opts` keeps the rest.

    Builds on any override already in place.
    """
    def merge_env_override(app \\ :portal, key, value) do
      Process.put(pdict_key_function(app, key), deep_merge(fetch_env!(app, key), value))
      :ok
    end

    @doc """
    Removes a key from the application env for the current process.

        delete_env_override(:portal, Portal.Google.APIClient, [:req_opts, :retry])

    Without a path the whole override is dropped.
    """
    def delete_env_override(app \\ :portal, key, path \\ [])

    def delete_env_override(app, key, []) do
      Process.delete(pdict_key_function(app, key))
      :ok
    end

    def delete_env_override(app, key, path) when is_list(path) do
      Process.put(pdict_key_function(app, key), delete_in(fetch_env!(app, key), path))
      :ok
    end

    defp deep_merge(base, override) when is_list(base) and is_list(override) do
      if Keyword.keyword?(base) and Keyword.keyword?(override) do
        Keyword.merge(base, override, fn _key, base_value, override_value ->
          deep_merge(base_value, override_value)
        end)
      else
        override
      end
    end

    defp deep_merge(_base, override), do: override

    defp delete_in(keyword, [key]) when is_list(keyword), do: Keyword.delete(keyword, key)

    defp delete_in(keyword, [key | rest]) when is_list(keyword) do
      case Keyword.fetch(keyword, key) do
        {:ok, nested} -> Keyword.put(keyword, key, delete_in(nested, rest))
        :error -> keyword
      end
    end

    defp delete_in(value, _path), do: value

    def put_system_env_override(key, value) when is_atom(key) do
      Process.put({Portal.Config.Resolver, key}, {:env, value})
      :ok
    end

    @doc """
    Attempts to override application env configuration from one of 3 sources (in this exact order):
      * takes it from process dictionary of a current process;
      * takes it from process dictionary of a last process in $ancestors stack.
      * takes it from process dictionary of a last process in $callers stack;

    This function is especially useful when some options (eg. request endpoint) needs to be overridden
    in test environment (eg. to send those requests to Req.Test).
    """
    def fetch_env!(app, key) do
      application_env = Application.fetch_env!(app, key)

      pdict_key_function(app, key)
      |> Portal.Config.Resolver.fetch_process_env()
      |> case do
        {:ok, override} ->
          override

        :error ->
          application_env
      end
    end

    def get_env(app, key, default \\ nil) do
      application_env = Application.get_env(app, key, default)

      pdict_key_function(app, key)
      |> Portal.Config.Resolver.fetch_process_env()
      |> case do
        {:ok, override} ->
          override

        :error ->
          application_env
      end
    end

    defp pdict_key_function(app, key), do: {app, key}
  end
end
