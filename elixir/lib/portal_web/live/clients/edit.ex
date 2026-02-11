defmodule PortalWeb.Clients.Edit do
  use PortalWeb, :live_view
  alias Portal.Presence.Clients
  alias __MODULE__.Database

  def mount(%{"id" => id}, _session, socket) do
    client = Database.get_client!(id, socket.assigns.subject)
    changeset = update_changeset(client, %{})

    socket =
      assign(socket,
        client: client,
        form: to_form(changeset),
        page_title: "Edit Client #{client.name}"
      )

    {:ok, socket, temporary_assigns: [form: %Phoenix.HTML.Form{}]}
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
                <.input
                  label="Name"
                  field={@form[:name]}
                  placeholder="Full Name"
                  phx-debounce="300"
                  required
                />
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
      update_changeset(socket.assigns.client, attrs)
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"client" => attrs}, socket) do
    changeset = update_changeset(socket.assigns.client, attrs)

    with {:ok, client} <- Database.update_client(changeset, socket.assigns.subject) do
      socket = push_navigate(socket, to: ~p"/#{socket.assigns.account}/clients/#{client}")
      {:noreply, socket}
    else
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp update_changeset(client, attrs) do
    import Ecto.Changeset
    update_fields = ~w[name]a
    required_fields = ~w[external_id name]a

    client
    |> cast(attrs, update_fields)
    |> validate_required(required_fields)
    |> Portal.Client.changeset()
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{Presence.Clients, Safe}
    alias Portal.Client

    def get_client!(id, subject) do
      from(c in Client, as: :clients)
      |> where([clients: c], c.id == ^id)
      |> preload(:actor)
      |> Safe.scoped(subject, :replica)
      |> Safe.one!(fallback_to_primary: true)
    end

    def update_client(changeset, subject) do
      case Safe.scoped(changeset, subject) |> Safe.update() do
        {:ok, updated_client} ->
          {:ok, Clients.preload_clients_presence([updated_client]) |> List.first()}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
