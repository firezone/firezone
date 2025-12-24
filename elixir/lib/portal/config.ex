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
    fetch_env!(:domain, :enabled_features)
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
    def put_env_override(app \\ :domain, key, value) do
      Process.put(pdict_key_function(app, key), value)
      :ok
    end

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
    in test environment (eg. to send those requests to Bypass).
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
        fetch_env!(:domain, :enabled_features)
        |> Keyword.put(feature, value)

      put_env_override(:enabled_features, enabled_features)
    end

    defp pdict_key_function(app, key), do: {app, key}
  end
end
