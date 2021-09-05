defmodule FzHttp.Release do
  @moduledoc """
  Adds common tasks to the production app because Mix is not available.
  """

  alias FzHttp.{Repo, Users, Users.User}
  import Ecto.Query, only: [from: 2]
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
    load_app()

    if Repo.exists?(from u in User, where: u.email == ^email()) do
      change_password(email(), default_password())
    else
      Users.create_user(
        email: email(),
        password: default_password(),
        password_confirmation: default_password()
      )
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

  defp default_password do
    Application.fetch_env!(@app, :default_admin_password)
  end
end
