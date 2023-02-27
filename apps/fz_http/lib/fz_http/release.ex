defmodule FzHttp.Release do
  @moduledoc """
  Adds common tasks to the production app because Mix is not available.
  """

  alias FzHttp.{
    ApiTokens,
    Repo,
    Users,
    Users.User
  }

  import Ecto.Query, only: [from: 2]
  require Logger

  @app :fz_http

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def create_admin_user do
    boot_database_app()

    if Repo.exists?(from u in User, where: u.email == ^email()) do
      change_password(email(), default_password())
      {:ok, user} = reset_role(email(), :admin)

      # Notify the user
      Logger.info("Password for user specified by ADMIN_EMAIL reset to DEFAULT_ADMIN_PASSWORD!")

      {:ok, user}
    else
      with {:ok, user} <-
             Users.create_admin_user(%{
               email: email(),
               password: default_password(),
               password_confirmation: default_password()
             }) do
        # Notify the user
        Logger.info(
          "An admin user specified by ADMIN_EMAIL is created with a DEFAULT_ADMIN_PASSWORD!"
        )

        {:ok, user}
      else
        {:error, changeset} ->
          Logger.error("Failed to create admin user: #{inspect(changeset.errors)}")
          {:error, changeset}
      end
    end
  end

  def create_api_token(device \\ :stdio) do
    boot_database_app()

    device
    |> IO.write(default_admin_user() |> mint_jwt())
  end

  def change_password(email, password) do
    params = %{
      "password" => password,
      "password_confirmation" => password
    }

    {:ok, user} = Users.fetch_user_by_email(email)
    {:ok, _user} = Users.admin_update_user(user, params)
  end

  def reset_role(email, role) do
    {:ok, user} = Users.fetch_user_by_email(email)
    Users.update_user_role(user, role)
  end

  def repos do
    FzHttp.Config.fetch_env!(@app, :ecto_repos)
  end

  defp email do
    FzHttp.Config.fetch_env!(@app, :admin_email)
  end

  defp set_supervision_tree_mode(mode) do
    Application.put_env(@app, :supervision_tree_mode, mode)
  end

  defp default_admin_user do
    case Users.fetch_user_by_email(email()) do
      {:ok, user} -> user
      {:error, :not_found} -> nil
    end
  end

  defp mint_jwt(%User{} = user) do
    {:ok, api_token} = ApiTokens.create_user_api_token(user, %{})

    {:ok, secret, _claims} =
      FzHttpWeb.Auth.JSON.Authentication.fz_encode_and_sign(api_token, user)

    secret
  end

  defp boot_database_app do
    load_app()
    set_supervision_tree_mode(:database)
    start_app()
  end

  defp load_app do
    Application.load(@app)

    # Fixes ssl startup when connecting to SSL DBs.
    # See https://elixirforum.com/t/ssl-connection-cannot-be-established-using-elixir-releases/25444/5
    Application.ensure_all_started(:ssl)
  end

  defp start_app do
    Application.ensure_all_started(@app)
  end

  defp default_password do
    FzHttp.Config.fetch_env!(@app, :default_admin_password)
  end
end
