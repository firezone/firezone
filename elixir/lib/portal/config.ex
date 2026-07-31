defmodule Portal.Config do
  alias Portal.Config.{Definition, Definitions, Errors, Validator, Fetcher}

  def fetch_resolved_configs!(account_id, keys, opts \\ []) do
    for {key, {_source, value}} <-
          fetch_resolved_configs_with_sources!(account_id, keys, opts),
        into: %{} do
      {key, value}
    end
  end

  def fetch_resolved_configs_with_sources!(_account_id, keys, _opts \\ []) do
    env_var_to_config = System.get_env()

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
  def env_var_to_config!(module \\ Definitions, key, env_var_to_config \\ System.get_env()) do
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
  def env_var_to_config(module \\ Definitions, key, env_var_to_config \\ System.get_env()) do
    case Fetcher.fetch_source_and_config(module, key, env_var_to_config) do
      {:ok, _source, value} ->
        value

      {:error, _reason} ->
        nil
    end
  end

  def config_changeset(changeset, schema_key, config_key \\ nil) do
    config_key = config_key || schema_key

    {type, {_resolve_opts, validate_opts, _dump_opts, _debug_opts}} =
      Definition.fetch_spec_and_opts!(Definitions, config_key)

    with {_data_or_changes, value} <- Ecto.Changeset.fetch_field(changeset, schema_key),
         {:error, values_and_errors} <- Validator.validate(config_key, value, type, validate_opts) do
      values_and_errors
      |> List.wrap()
      |> Enum.flat_map(fn {_value, errors} -> errors end)
      |> Enum.uniq()
      |> Enum.reduce(changeset, fn error, changeset ->
        Ecto.Changeset.add_error(changeset, schema_key, error)
      end)
    else
      :error -> changeset
      {:ok, _value} -> changeset
    end
  end

  ## Feature flag helpers

  def global_feature_enabled?(feature) do
    fetch_env!(:portal, :enabled_features)
    |> Keyword.fetch!(feature)
  end

  def sign_up_enabled? do
    global_feature_enabled?(:sign_up)
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
    Overrides application env for the current process, merging nested keyword
    lists rather than replacing them.

    `put_env_override/3` merges only the top level, so overriding one entry of a
    nested list such as `:req_opts` drops everything else configured under it.
    That silently hides whatever `config.exs` set, leaving tests agreeing with a
    configuration no environment actually runs. Prefer this when overriding part
    of a nested list.

    Builds on any override already in place, so repeated calls accumulate.
    """
    def merge_env_override(app \\ :portal, key, value) do
      Process.put(pdict_key_function(app, key), deep_merge(fetch_env!(app, key), value))
      :ok
    end

    @doc """
    Removes a key from the application env for the current process.

    Given a path it reaches into nested keyword lists, so a test can run against
    the configured value minus a single entry:

        delete_env_override(:portal, Portal.Google.APIClient, [:req_opts, :retry])

    Without a path the whole override is dropped and the configured value
    applies again.
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

    def feature_flag_override(feature, value) do
      enabled_features =
        fetch_env!(:portal, :enabled_features)
        |> Keyword.put(feature, value)

      put_env_override(:enabled_features, enabled_features)
    end

    defp pdict_key_function(app, key), do: {app, key}
  end
end
