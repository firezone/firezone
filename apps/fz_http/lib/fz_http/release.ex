defmodule FzHttp.Release do
  alias FzHttp.{ApiTokens, Users}
  require Logger

  def migrate do
    load_app()

    for repo <- FzHttp.Config.fetch_env!(:fz_http, :ecto_repos) do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def create_admin_user do
    boot_database_app()

    email = email()

    with {:ok, _user} <- Users.fetch_user_by_email(email) do
      change_password(email(), default_password())
      {:ok, user} = reset_role(email(), :admin)

      # Notify the user
      Logger.info(
        "Password for user specified by DEFAULT_ADMIN_EMAIL reset to DEFAULT_ADMIN_PASSWORD!"
      )

      {:ok, user}
    else
      {:error, :not_found} ->
        with {:ok, user} <-
               Users.create_user(:admin, %{
                 email: email(),
                 password: default_password(),
                 password_confirmation: default_password()
               }) do
          # Notify the user
          Logger.info(
            "An admin user specified by DEFAULT_ADMIN_EMAIL is created with a DEFAULT_ADMIN_PASSWORD!"
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
    {:ok, _user} = Users.update_user(user, params)
  end

  def reset_role(email, role) do
    {:ok, user} = Users.fetch_user_by_email(email)
    Users.update_user(user, %{role: role})
  end

  def repos do
    FzHttp.Config.fetch_env!(:fz_http, :ecto_repos)
  end

  defp email do
    FzHttp.Config.fetch_env!(:fz_http, :admin_email)
  end

  defp set_supervision_tree_mode(mode) do
    Application.put_env(:fz_http, :supervision_tree_mode, mode)
  end

  defp default_admin_user do
    case Users.fetch_user_by_email(email()) do
      {:ok, user} -> user
      {:error, :not_found} -> nil
    end
  end

  defp mint_jwt(%Users.User{} = user) do
    {:ok, api_token} = ApiTokens.create_api_token(user, %{})
    {:ok, secret, _claims} = FzHttpWeb.Auth.JSON.Authentication.encode_and_sign(api_token)
    secret
  end

  defp boot_database_app do
    load_app()
    set_supervision_tree_mode(:database)
    start_app()
  end

  defp load_app do
    Application.load(:fz_http)

    # Fixes ssl startup when connecting to SSL DBs.
    # See https://elixirforum.com/t/ssl-connection-cannot-be-established-using-elixir-releases/25444/5
    Application.ensure_all_started(:ssl)
  end

  defp start_app do
    Application.ensure_all_started(:fz_http)
  end

  defp default_password do
    FzHttp.Config.fetch_env!(:fz_http, :default_admin_password)
  end
end
