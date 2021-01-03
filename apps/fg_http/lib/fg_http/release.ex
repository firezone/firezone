defmodule FgHttp.Release do
  @moduledoc """
  Configures the Mix Release or something
  """

  alias FgHttp.{Repo, Users, Users.User}

  @app :fg_http

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

  def create_admin_user do
    start_app()

    unless Repo.exists?(User) do
      email = "admin@fireguard.local"
      password = secret(12)
      Users.create_user(
        email: email,
        password: password,
        password_confirmation: password
      )

      log_email_password(email, password)
    end
  end

  defp start_app do
    load_app()
    Application.put_env(@app, :minimal, true)
    Application.ensure_all_started(@app)
  end

  defp secret(length) do
    :crypto.strong_rand_bytes(length) |> Base.encode64() |> binary_part(0, length)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end

  defp log_email_password(email, password) do
    IO.puts("================================================================================")
    IO.puts("FireGuard user created! Save this information because it will NOT be shown again.")
    IO.puts("Email: #{email}")
    IO.puts("Password: #{password}")
    IO.puts("================================================================================")
  end
end
