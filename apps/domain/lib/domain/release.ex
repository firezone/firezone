defmodule Domain.Release do
  alias Domain.{ApiTokens, Users}
  require Logger

  @app :domain
  @repos Application.compile_env!(:domain, :ecto_repos)

  def migrate do
    for repo <- @repos do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def create_admin_user do
    start_domain_app()

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
    start_domain_app()

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

  defp email do
    Domain.Config.fetch_env!(:domain, :admin_email)
  end

  defp default_admin_user do
    case Users.fetch_user_by_email(email()) do
      {:ok, user} -> user
      {:error, :not_found} -> nil
    end
  end

  defp mint_jwt(%Users.User{} = user) do
    {:ok, api_token} = ApiTokens.create_api_token(user, %{})
    {:ok, secret, _claims} = Web.Auth.JSON.Authentication.fz_encode_and_sign(api_token)
    secret
  end

  defp start_domain_app do
    # Load the app
    :ok = Application.ensure_loaded(@app)

    # Start the app dependencies
    {:ok, _apps} = Application.ensure_all_started(@app)
  end

  defp default_password do
    Domain.Config.fetch_env!(:domain, :default_admin_password)
  end
end
