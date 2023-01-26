defmodule FzHttp.Config.Errors do
  require Logger

  def legacy_key_used(key, legacy_key, removed_at) do
    Logger.warn(
      "A legacy configuration option '#{legacy_key}' is used and it will be removed in v#{removed_at}." <>
        "Please use '#{key}' configuration option instead."
    )
  end

  def missing_required_config(key, db_configurations) do
    message =
      [
        "Missing required configuration value for '#{key}'.",
        env_example(key),
        db_example(db_configurations, key),
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

  defp db_example(db_configurations, key) do
    if Map.has_key?(db_configurations, key) do
      """
      Or you can set this configuration in the database by either setting it via the admin panel,
      or by running an SQL query:

          cd $HOME/.firezone
          docker compose exec postgres psql \
            -U postgres \
            -h 127.0.0.1 \
            -d firezone \
            -c "UPDATE configurations SET #{key} = 'YOUR_VALUE'"
      """
    end
  end
end
