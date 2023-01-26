defmodule FzHttp.Config do
  alias FzHttp.Configurations
  alias FzHttp.Config.{Definitions, Resolver, Caster, Validator, Errors}

  def validate_runtime_config do
    db_configurations = Configurations.get_configuration!()
    env_configurations = System.get_env()

    Definitions.configs()
    |> Enum.reduce([""], fn key, reports ->
      {key, source, info} =
        build_config_item(Definitions, key, env_configurations, db_configurations)

      values =
        info
        |> List.wrap()
        |> Enum.map(&elem(&1, 0))

      errors =
        info
        |> List.wrap()
        |> Enum.flat_map(&elem(&1, 1))
        |> Enum.uniq()

      if errors == [] do
        reports
      else
        reports ++ [Errors.report_errors(key, source, values, errors)]
      end
    end)
    |> Enum.join("\n\n\n~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n\n")
    |> raise()
  end

  defp build_config_item(module, key, env_configurations, db_configurations) do
    {type, opts} = apply(module, key, [])
    {resolve_opts, opts} = Keyword.split(opts, [:legacy_keys, :default])
    {validate_opts, opts} = Keyword.split(opts, [:changeset])
    {required?, opts} = Keyword.pop(opts, :required, true)

    if opts != [], do: Errors.invalid_spec(key, opts)

    case Resolver.resolve(key, env_configurations, db_configurations, resolve_opts) do
      {:not_found, value} ->
        errors = if required?, do: [{"is required", validation: :required}], else: []
        {key, :not_found, {value, errors}}

      {source, value} ->
        value = Caster.cast(value, type)
        {key, source, Validator.validate(key, value, type, validate_opts)}
    end
  end

  if Mix.env() != :test do
    defdelegate fetch_env!(app, key), to: Application
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

    defp key_function(app, key), do: String.to_atom("#{app}-#{key}")
  end
end
