defmodule Web.Clients.Edit do
  use Web, :live_view
  alias Domain.Clients

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, client} <- Clients.fetch_client_by_id(id, socket.assigns.subject),
         nil <- client.deleted_at do
      changeset = Clients.change_client(client)

      socket =
        assign(socket,
          client: client,
          form: to_form(changeset),
          page_title: "Edit Client #{client.name}"
        )

      {:ok, socket, temporary_assigns: [form: %Phoenix.HTML.Form{}]}
    else
      _other -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/clients"}>Clients</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/clients/#{@client}"}>
        {@client.name}
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/clients/#{@client}/edit"}>
        Edit
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Editing client: <code>{@client.name}</code>
      </:title>
      <:content>
        <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
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
      </:content>
    </.section>
    """
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
      socket = push_navigate(socket, to: ~p"/#{socket.assigns.account}/clients/#{client}")
      {:noreply, socket}
    else
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end
