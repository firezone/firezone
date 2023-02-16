defmodule FzHttp.Config do
  alias FzHttp.Repo
  alias FzHttp.Config.{Definition, Definitions, Validator, Errors, Resolver, Fetcher}
  alias FzHttp.Config.{Configuration}

  def fetch_source_and_config!(key) do
    db_config = maybe_fetch_db_config!(key)
    env_config = System.get_env()

    case Fetcher.fetch_source_and_config(Definitions, key, db_config, env_config) do
      {:ok, source, config} ->
        {source, config}

      {:error, reason} ->
        Errors.raise_error!(reason)
    end
  end

  def fetch_source_and_configs!(keys) when is_list(keys) do
    db_config = maybe_fetch_db_config!(keys)
    env_config = System.get_env()

    for key <- keys, into: %{} do
      case Fetcher.fetch_source_and_config(Definitions, key, db_config, env_config) do
        {:ok, source, config} ->
          {key, {source, config}}

        {:error, reason} ->
          Errors.raise_error!(reason)
      end
    end
  end

  # TODO: there is no need to validate when we fetch it
  def fetch_config(key) do
    # TODO: we can pass a callback to fetch configs instead
    db_config = maybe_fetch_db_config!(key)
    env_config = System.get_env()

    with {:ok, _source, config} <-
           Fetcher.fetch_source_and_config(Definitions, key, db_config, env_config) do
      {:ok, config}
    end
  end

  def fetch_config!(key) do
    case fetch_config(key) do
      {:ok, config} ->
        config

      {:error, reason} ->
        Errors.raise_error!(reason)
    end
  end

  def fetch_configs!(keys) do
    for {key, {_source, value}} <- fetch_source_and_configs!(keys), into: %{} do
      {key, value}
    end
  end

  defp maybe_fetch_db_config!(keys) when is_list(keys) do
    if Enum.any?(keys, &(&1 in FzHttp.Config.Configuration.__schema__(:fields))) do
      fetch_db_config!()
    else
      %{}
    end
  end

  defp maybe_fetch_db_config!(key) do
    if key in FzHttp.Config.Configuration.__schema__(:fields) do
      fetch_db_config!()
    else
      %{}
    end
  end

  def fetch_db_config!() do
    Repo.one!(Configuration)
  end

  def change_config(%Configuration{} = config \\ fetch_db_config!()) do
    Configuration.Changeset.changeset(config, %{})
  end

  def update_config(%Configuration{} = config, attrs) do
    with {:ok, config} <- Repo.update(Configuration.Changeset.changeset(config, attrs)) do
      FzHttp.SAML.StartProxy.refresh(config.saml_identity_providers)
      {:ok, config}
    end
  end

  def put_config!(key, value) do
    with {:ok, config} <- update_config(fetch_db_config!(), %{key => value}) do
      config
    else
      {:error, reason} -> raise "can not update config: #{inspect(reason)}"
    end
  end

  @doc """
  Similar to `compile_config/2` but raises an error if the configuration is invalid.

  This function does not resolve values from the database because it's intended use is during
  compilation and before application boot (in `config/runtime.exs`).

  If you need to resolve values from the database, use `fetch_config/1` or `fetch_config!/1`.
  """
  def compile_config!(module \\ Definitions, key, env_configurations \\ System.get_env()) do
    case Fetcher.fetch_source_and_config(module, key, %{}, env_configurations) do
      {:ok, _source, value} ->
        value

      {:error, reason} ->
        Errors.raise_error!(reason)
    end
  end

  def validate_runtime_config!(
        module \\ Definitions,
        db_config \\ fetch_db_config!(),
        env_config \\ System.get_env()
      ) do
    module.configs()
    |> Enum.flat_map(fn {module, key} ->
      case Fetcher.fetch_source_and_config(module, key, db_config, env_config) do
        {:ok, _source, _value} -> []
        {:error, reason} -> [reason]
      end
    end)
    |> case do
      [] -> :ok
      errors -> Errors.raise_error!(errors)
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

  def vpn_sessions_expire? do
    freq = fetch_config!(:vpn_session_duration)
    freq > 0 && freq < Configuration.Changeset.max_vpn_session_duration()
  end

  if Mix.env() != :test do
    defdelegate fetch_env!(app, key), to: Application
  else
    def put_env_override(app \\ :fz_http, key, value) do
      Process.put(pdict_key_function(app, key), value)
      :ok
    end

    def put_system_env_override(key, value) do
      Process.put({Resolver, key}, {:env, value})
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
      |> Resolver.fetch_process_env()
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
