defmodule FzHttp.Release do
  @moduledoc """
  Adds common tasks to the production app because Mix is not available.
  """

  alias FzHttp.{Repo, Users, Users.User}
  require Logger

  @app :fz_http

  def gen_secret(length) when length > 31 do
    IO.puts(secret(length))
  end

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  # App should be loaded at this point; call with `rpc` not `eval`
  def create_admin_user do
    unless Repo.exists?(User) do
      password = secret(12)

      Users.create_user(
        email: email(),
        password: password,
        password_confirmation: password
      )

      log_email_password(email(), password)
    end
  end

  def change_password(email, password) do
    params = %{
      "password" => password,
      "password_confirmation" => password
    }

    {:ok, _user} =
      Users.get_user!(email: email)
      |> Users.update_user(params)
  end

  defp secret(length) do
    :crypto.strong_rand_bytes(length) |> Base.encode64() |> binary_part(0, length)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp email do
    Application.fetch_env!(@app, :admin_email)
  end

  defp load_app do
    Application.load(@app)
  end

  defp log_email_password(email, password) do
    Logger.info(
      "================================================================================="
    )

    Logger.info(
      "FireZone user created! Save this information because it will NOT be shown again."
    )

    Logger.info("Use this to log into the Web UI at #{FzHttpWeb.Endpoint.url()}.")
    Logger.info("Email: #{email}")
    Logger.info("Password: #{password}")

    Logger.info(
      "================================================================================="
    )
  end
end
