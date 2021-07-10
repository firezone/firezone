defmodule FzHttpWeb.PasswordResetLive.Edit do
  @moduledoc """
  Handles PasswordReset Live Views.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.PasswordResets

  def mount(%{"reset_token" => reset_token}, _session, socket) do
    changeset =
      PasswordResets.get_password_reset!(reset_token: reset_token)
      |> PasswordResets.edit_password_reset()

    {:ok, assign(socket, :changeset, changeset)}
  end

  def handle_event(
        "change_password",
        %{"password_reset" => %{"reset_token" => reset_token} = params},
        socket
      ) do
    case PasswordResets.get_password_reset(reset_token: reset_token) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Reset token invalid. Try resetting your password again.")
         |> assign(:changeset, PasswordResets.new_password_reset())}

      password_reset ->
        case PasswordResets.update_password_reset(password_reset, params) do
          {:ok, _password_reset} ->
            {:noreply,
             socket
             |> put_flash(:info, "Password reset successfully. You may now sign in.")
             |> push_redirect(to: Routes.session_new_path(socket, :new))}

          {:error, changeset} ->
            {:noreply,
             socket
             |> put_flash(:error, "Error updating password.")
             |> assign(:changeset, changeset)}
        end
    end
  end
end
