defmodule Portal.Config.Errors do
  alias Portal.Config.Definition
  require Logger

  def raise_error!(errors) do
    errors
    |> format_error()
    |> raise()
  end

  defp format_error({{nil, ["is required"]}, metadata}) do
    module = Keyword.fetch!(metadata, :module)
    key = Keyword.fetch!(metadata, :key)

    [
      "Missing required configuration value for '#{key}'.",
      "## How to fix?",
      env_example(key),
      format_doc(module, key)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp format_error({values_and_errors, metadata}) do
    source = Keyword.fetch!(metadata, :source)
    module = Keyword.fetch!(metadata, :module)
    key = Keyword.fetch!(metadata, :key)

    [
      "Invalid configuration for '#{key}' retrieved from #{source(source)}.",
      "Errors:",
      format_errors(module, key, values_and_errors),
      format_doc(module, key)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp format_error(errors) do
    error_messages = Enum.map(errors, &format_error(&1))

    (["Found #{length(errors)} configuration errors:"] ++ error_messages)
    |> Enum.join("\n\n\n~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n\n")
  end

  defp source({:app_env, key}), do: "application environment #{key}"
  defp source({:env, key}), do: "environment variable #{Portal.Config.Resolver.env_key(key)}"
  defp source(:default), do: "default value"

  defp format_errors(module, key, values_and_errors) do
    {_type, {_resolve_opts, _validate_opts, _dump_opts, debug_opts}} =
      Definition.fetch_spec_and_opts!(module, key)

    sensitive? = Keyword.get(debug_opts, :sensitive, false)

    values_and_errors
    |> List.wrap()
    |> Enum.map_join("\n", fn {value, errors} ->
      " - `#{format_value(sensitive?, value)}`: #{Enum.map_join(errors, ", ", &error_to_string/1)}"
    end)
  end

  defp error_to_string(error) when is_binary(error), do: error
  defp error_to_string(tuple) when is_tuple(tuple), do: inspect(tuple)

  defp format_value(true, _value), do: "**SENSITIVE-VALUE-REDACTED**"
  defp format_value(false, value), do: inspect(value)

  defp format_doc(module, key) do
    case module.fetch_doc(key) do
      {:error, :module_not_found} ->
        nil

      {:error, :chunk_not_found} ->
        nil

      :error ->
        nil

      {:ok, doc} ->
        """
        ## Documentation

        #{doc}
        """
    end
  end

  def legacy_key_used(key, legacy_key, removed_at) do
    Logger.warning(
      "A legacy configuration option '#{legacy_key}' is used and it will be removed in v#{removed_at}. " <>
        "Please use '#{Portal.Config.Resolver.env_key(key)}' configuration option instead."
    )
  end

  def invalid_spec(key, opts) do
    raise "unknown options #{inspect(opts)} for configuration #{inspect(key)}"
  end

  defp env_example(key) do
    """
    ### Using environment variables

    You can set this configuration with an environment variable:

        #{Portal.Config.Resolver.env_key(key)}=YOUR_VALUE
    """
  end
end
