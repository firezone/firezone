defmodule FgHttpWeb.PasswordResetLive.New do
  @moduledoc """
  Handles PasswordReset Live Views.
  """
  use FgHttpWeb, :live_view

  alias FgHttp.{Email, Mailer, PasswordResets}

  def mount(_params, _session, socket) do
    changeset = PasswordResets.new_password_reset()
    {:ok, assign(socket, :changeset, changeset)}
  end

  def handle_event(
        "create_password_reset",
        %{"password_reset" => %{"email" => email}},
        socket
      ) do
    case PasswordResets.get_password_reset!(email: email) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Email not found.")
         |> assign(:changeset, PasswordResets.new_password_reset())}

      password_reset ->
        case PasswordResets.create_password_reset(password_reset, %{email: email}) do
          {:ok, password_reset} ->
            send_email(password_reset)

            {:noreply,
             socket
             |> put_flash(:info, "Check your email for the password reset link.")
             |> push_redirect(to: Routes.session_path(socket, :new))}

          {:error, changeset} ->
            {:noreply,
             socket
             |> put_flash(:error, "Error creating password reset.")
             |> assign(:changeset, changeset)}
        end
    end
  end

  defp send_email(password_reset) do
    Email.password_reset(password_reset)
    |> Mailer.deliver_later()
  end
end
