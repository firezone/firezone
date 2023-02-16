defmodule FzHttp.Config.Fetcher do
  alias FzHttp.Config.{Definition, Resolver, Caster, Validator}

  @spec fetch_source_and_config(
          module(),
          key :: atom(),
          db_configurations :: map(),
          env_configurations :: map()
        ) ::
          {:ok, Resolver.source(), term()} | {:error, {[String.t()], metadata: term()}}
  def fetch_source_and_config(module, key, %{} = db_configurations, %{} = env_configurations)
      when is_atom(module) and is_atom(key) do
    {type, {resolve_opts, validate_opts, dump_opts, _debug_opts}} =
      Definition.fetch_spec_and_opts!(module, key)

    with {:ok, {source, value}} <-
           resolve_value(module, key, env_configurations, db_configurations, resolve_opts),
         {:ok, value} <- cast_value(module, key, source, value, type),
         {:ok, value} <- validate_value(module, key, source, value, type, validate_opts) do
      if dump_cb = Keyword.get(dump_opts, :dump) do
        {:ok, source, dump_cb.(value)}
      else
        {:ok, source, value}
      end
    end
  end

  defp resolve_value(module, key, env_configurations, db_configurations, opts) do
    with :error <- Resolver.resolve(key, env_configurations, db_configurations, opts) do
      {:error, {{nil, ["is required"]}, module: module, key: key, source: :not_found}}
    end
  end

  defp cast_value(module, key, source, value, type) do
    case Caster.cast(value, type) do
      {:ok, value} ->
        {:ok, value}

      {:error, %Jason.DecodeError{} = decode_error} ->
        reason = Jason.DecodeError.message(decode_error)
        {:error, {{value, [reason]}, module: module, key: key, source: source}}

      {:error, reason} ->
        {:error, {{value, [reason]}, module: module, key: key, source: source}}
    end
  end

  defp validate_value(module, key, source, value, type, opts) do
    case Validator.validate(key, value, type, opts) do
      {:ok, value} ->
        {:ok, value}

      {:error, values_and_errors} ->
        {:error, {values_and_errors, module: module, key: key, source: source}}
    end
  end
end
