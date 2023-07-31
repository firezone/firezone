defmodule Domain.Config do
  alias Domain.{Repo, Auth}
  alias Domain.Config.Authorizer
  alias Domain.Config.{Definition, Definitions, Validator, Errors, Fetcher}
  alias Domain.Config.Configuration

  def fetch_resolved_configs!(account_id, keys, opts \\ []) do
    for {key, {_source, value}} <-
          fetch_resolved_configs_with_sources!(account_id, keys, opts),
        into: %{} do
      {key, value}
    end
  end

  def fetch_resolved_configs_with_sources!(account_id, keys, opts \\ []) do
    {db_config, env_config} = maybe_load_sources(account_id, opts, keys)

    for key <- keys, into: %{} do
      case Fetcher.fetch_source_and_config(Definitions, key, db_config, env_config) do
        {:ok, source, config} ->
          {key, {source, config}}

        {:error, reason} ->
          Errors.raise_error!(reason)
      end
    end
  end

  defp maybe_load_sources(account_id, opts, keys) when is_list(keys) do
    ignored_sources = Keyword.get(opts, :ignore_sources, []) |> List.wrap()

    one_of_keys_is_stored_in_db? =
      Enum.any?(keys, &(&1 in Domain.Config.Configuration.__schema__(:fields)))

    db_config =
      if :db not in ignored_sources and one_of_keys_is_stored_in_db?,
        do: get_account_config_by_account_id(account_id),
        else: %{}

    # credo:disable-for-lines:4
    env_config =
      if :env not in ignored_sources,
        do: System.get_env(),
        else: %{}

    {db_config, env_config}
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

  ## Configuration stored in database

  def get_account_config_by_account_id(account_id) do
    queryable = Configuration.Query.by_account_id(account_id)
    Repo.one(queryable) || %Configuration{account_id: account_id}
  end

  def fetch_account_config(%Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_permission()) do
      {:ok, get_account_config_by_account_id(subject.account.id)}
    end
  end

  def change_account_config(%Configuration{} = configuration, attrs \\ %{}) do
    Configuration.Changeset.changeset(configuration, attrs)
  end

  def update_config(%Configuration{} = configuration, attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_permission()) do
      update_config(configuration, attrs)
    end
  end

  def update_config(%Configuration{} = configuration, attrs) do
    Configuration.Changeset.changeset(configuration, attrs)
    |> Repo.insert_or_update()
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
      Process.put({Domain.Config.Resolver, key}, {:env, value})
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
      |> Domain.Config.Resolver.fetch_process_env()
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
      |> Domain.Config.Resolver.fetch_process_env()
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
