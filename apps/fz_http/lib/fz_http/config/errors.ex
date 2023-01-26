defmodule FzHttp.Config.Errors do
  require Logger

  def report_errors(key, :not_found, _values, [{_message, [validation: :required]}]) do
    [
      "Missing required configuration value for '#{key}'.",
      env_example(key),
      db_example(key)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  def report_errors(key, source, values, errors) do
    [
      "Invalid configuration value `#{format_values(values)}` for '#{key}' retrieved from #{source(source)}.",
      format_errors(errors)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp format_values([value]) do
    inspect(value)
  end

  defp format_values(values) do
    values
    |> Enum.map(&inspect/1)
    |> Enum.join(", ")
  end

  defp source({:env, key}), do: "environment variable #{key}"
  defp source({:db, key}), do: "database configuration #{key}"
  defp source(:default), do: "default value"

  defp format_errors(errors) do
    errors
    |> Enum.map(&format_error/1)
    |> Enum.join("\n")
  end

  defp format_error({message, _opts}) do
    "  - #{message}"
  end

  def legacy_key_used(key, legacy_key, removed_at) do
    Logger.warn(
      "A legacy configuration option '#{legacy_key}' is used and it will be removed in v#{removed_at}." <>
        "Please use '#{key}' configuration option instead."
    )
  end

  def invalid_spec(key, opts) do
    raise "unknown options #{inspect(opts)} for configuration #{inspect(key)}"
  end

  def missing_required_config(key) do
    message =
      [
        "Missing required configuration value for '#{key}'.",
        env_example(key),
        db_example(key),
        "You can find more information on configuration here: https://docs.firezone.dev/reference/env-vars/#environment-variable-listing"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    # TODO
    Logger.warn(message)
    # raise message
  end

  defp env_example(key) do
    """
    You can set this configuration via environment variable by adding it to `.env` file:

        #{FzHttp.Config.Resolver.env_key(key)}=YOUR_VALUE
    """
  end

  defp db_example(key) do
    if key in FzHttp.Configurations.Configuration.__schema__(:fields) do
      """
      Or you can set this configuration in the database by either setting it via the admin panel,
      or by running an SQL query:

          cd $HOME/.firezone
          docker compose exec postgres psql \\
            -U postgres \\
            -h 127.0.0.1 \\
            -d firezone \\
            -c "UPDATE configurations SET #{key} = 'YOUR_VALUE'"
      """
    end
  end
end
