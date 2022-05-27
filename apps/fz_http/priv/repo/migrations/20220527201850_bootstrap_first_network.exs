defmodule FzHttp.Repo.Migrations.BootstrapFirstNetwork do
  use Ecto.Migration

  # Allow for testing this migration in dev / test.
  # A sample can be pulled from a running instance.
  @dev_config_path "tmp/firezone-running.json"

  # Use this in prod
  @prod_config_path "/etc/firezone/firezone-running.json"

  def change do
    if config_exists?(@config_path) do
      firezone_config = running_config(@config_path)["firezone"]
    else
      Logger.warn("Existing config #{@config_path} not found. Skipping migration.")
    end
  end

  defp running_config do
    config_path()
    |> File.read()
    |> Jason.decode!()
  end

  defp config_path do
    if File.exist?(@dev_config_path) do
      @dev_config_path
    else
      @prod_config_path
    end
  end
end
