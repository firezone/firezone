defmodule Web.RelayGroups.Edit do
  use Web, :live_view
  alias Domain.Relays

  def mount(%{"id" => id} = _params, _session, socket) do
    with {:ok, group} <- Relays.fetch_group_by_id(id, socket.assigns.subject) do
      changeset = Relays.change_group(group)
      {:ok, assign(socket, group: group, form: to_form(changeset))}
    else
      {:error, :not_found} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def handle_event("change", %{"group" => attrs}, socket) do
    changeset =
      Relays.change_group(socket.assigns.group, attrs)
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"group" => attrs}, socket) do
    with {:ok, group} <-
           Relays.update_group(socket.assigns.group, attrs, socket.assigns.subject) do
      socket = redirect(socket, to: ~p"/#{socket.assigns.account}/relay_groups/#{group}")
      {:noreply, socket}
    else
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/relay_groups"}>Relay Instance Groups</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/relay_groups/#{@group}"}>
        <%= @group.name %>
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/relay_groups/#{@group}/edit"}>Edit</.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Editing Relay Instance Group <code><%= @group.name %></code>
      </:title>
    </.header>

    <section class="bg-white dark:bg-gray-900">
      <div class="py-8 px-4 mx-auto max-w-2xl lg:py-16">
        <.form for={@form} phx-change={:change} phx-submit={:submit}>
          <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
            <div>
              <.input
                label="Name Prefix"
                field={@form[:name]}
                placeholder="Name of this Relay Instance Group"
                required
              />
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
