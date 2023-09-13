defmodule Web.Clients.Edit do
  use Web, :live_view
  alias Domain.Clients

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, client} <- Clients.fetch_client_by_id(id, socket.assigns.subject) do
      changeset = Clients.change_client(client)
      {:ok, assign(socket, client: client, form: to_form(changeset))}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def handle_event("change", %{"client" => attrs}, socket) do
    changeset =
      Clients.change_client(socket.assigns.client, attrs)
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"client" => attrs}, socket) do
    with {:ok, client} <-
           Clients.update_client(socket.assigns.client, attrs, socket.assigns.subject) do
      socket = redirect(socket, to: ~p"/#{socket.assigns.account}/clients/#{client}")
      {:noreply, socket}
    else
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/clients"}>Clients</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/clients/#{@client}"}>
        <%= @client.name %>
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/clients/#{@client}/edit"}>
        Edit
      </.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Editing client <code>Engineering</code>
      </:title>
    </.header>
    <!-- Update Group -->
    <section class="bg-white dark:bg-gray-900">
      <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
        <h2 class="mb-4 text-xl font-bold text-gray-900 dark:text-white">Edit client details</h2>
        <.form for={@form} phx-change={:change} phx-submit={:submit}>
          <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
            <div>
              <.input label="Name" field={@form[:name]} placeholder="Full Name" required />
            </div>
          </div>
          <.submit_button>
            Save
          </.submit_button>
        </.form>
      </div>
    </section>
    """
  end
end
