defmodule FgHttpWeb.SessionLive.New do
  @moduledoc """
  Handles sign in.
  """
  use FgHttpWeb, :live_view

  alias FgHttp.{Sessions, Users, Util.FgCrypto}

  def mount(params, session, socket) do
    changeset = Sessions.new_session()
    {:ok, assign(socket, :changeset, changeset)}
  end

  def handle_event("sign_in", %{"session" => %{"email" => email, "password" => password}}, socket) do
    case Sessions.get_session(email: email) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Email not found.")
         |> assign(:changeset, Sessions.new_session())}

      record ->
        case Sessions.create_session(record, %{email: email, password: password}) do
          {:ok, session} ->
            redirect_to_sign_in(socket, session)

          {:error, changeset} ->
            {:noreply,
             socket
             |> put_flash(:error, "Error signing in. Check email and password are correct.")
             |> assign(:changeset, changeset)}
        end
    end
  end

  # Guess email if signups are disabled and only one user exists
  def email_field_opts(opts \\ []) do
    if Users.single_user?() and signups_disabled?() do
      opts ++ [value: Users.admin_email()]
    else
      opts
    end
  end

  defp redirect_to_sign_in(socket, session) do
    case create_sign_in_token(session) do
      {:ok, token} ->
        {:noreply, redirect(socket, to: Routes.session_path(socket, :create, token))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Error creating sign in token. Try again.")
         |> assign(:changeset, changeset)}
    end
  end

  defp create_sign_in_token(session) do
    token = FgCrypto.rand_string()

    params = %{"sign_in_token" => token, "sign_in_token_created_at" => DateTime.utc_now()}

    case Users.get_user!(session.id) |> Users.update_user(params) do
      {:ok, _count} ->
        {:ok, token}

      err ->
        err
    end
  end

  defp signups_disabled? do
    Application.fetch_env!(:fg_http, :disable_signup)
  end
end
