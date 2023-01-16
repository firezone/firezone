defmodule FzHttpWeb.UserLive.FormComponent do
  @moduledoc """
  Handles user form for admins.
  """
  use FzHttpWeb, :live_component

  alias FzHttp.Users

  @impl Phoenix.LiveComponent
  def update(%{action: :new} = assigns, socket) do
    changeset = Users.change_user()

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:changeset, changeset)}
  end

  @impl Phoenix.LiveComponent
  def update(%{action: :edit} = assigns, socket) do
    changeset = Users.change_user(assigns.user)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:changeset, changeset)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("save", %{"user" => user_params}, %{assigns: %{action: :new}} = socket) do
    case Users.create_unprivileged_user(user_params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:user, user)
         |> put_flash(:info, "User created successfully.")
         |> push_redirect(to: ~p"/users/#{user}")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:changeset, changeset)}
    end
  end

  @impl Phoenix.LiveComponent
  def handle_event("save", %{"user" => user_params}, %{assigns: %{action: :edit}} = socket) do
    user = socket.assigns.user

    case Users.admin_update_user(user, user_params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:user, user)
         |> put_flash(:info, "User updated successfully.")
         |> push_redirect(to: socket.assigns.return_to)}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end
end
