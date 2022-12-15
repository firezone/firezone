defmodule FzHttp.Repo.DataMigrations.MoveDefaultsToConfigurations do
  use Ecto.Migration

  alias FzHttp.Sites

  def change do
    execute("UPDATE configurations SET #{update_cols()}")
  end

  def update_cols do
    "#{update_cols_site()}#{update_cols_env()}" |> String.trim_trailing(",")
  end

  defp update_cols_site do
    site_defaults =
      Sites.wireguard_defaults()
      |> Map.put("vpn_session_duration", Sites.vpn_duration())

    for {key, value} <- site_defaults do
      column = if key != "vpn_session_duration", do: "default_client_#{key}", else: key

      "#{column}='#{value}',"
    end
  end

  defp update_cols_env do
    env_vars =
      %{
        "ipv4_enabled" => true,
        "ipv6_enabled" => true,
        "ipv4_network" => "10.3.2.0/24",
        "ipv6_network" => "fd00::3:2:0/120",
        "port" => 51_820
      }
      |> Map.map(fn {k, v} -> from_env(k, v) end)

    for {key, value} <- env_vars do
      column = if key == "port", do: "default_client_port", else: key

      "#{column}='#{value}',"
    end
  end

  defp from_env(name, default) do
    env_var = System.get_env("WIREGUARD_#{String.upcase(name)}")
    if env_var && env_var != "", do: env_var, else: default
  end
end
