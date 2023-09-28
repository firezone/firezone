defmodule Web.GatewayGroups.Edit do
  use Web, :live_view
  alias Domain.Gateways

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, group} <- Gateways.fetch_group_by_id(id, socket.assigns.subject) do
      changeset = Gateways.change_group(group)
      {:ok, assign(socket, group: group, form: to_form(changeset))}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def handle_event("delete:group[tags]", %{"index" => index}, socket) do
    changeset = socket.assigns.form.source
    values = Ecto.Changeset.fetch_field!(changeset, :tags) || []
    values = List.delete_at(values, String.to_integer(index))
    changeset = Ecto.Changeset.put_change(changeset, :tags, values)
    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("add:group[tags]", _params, socket) do
    changeset = socket.assigns.form.source
    values = Ecto.Changeset.fetch_field!(changeset, :tags) || []
    changeset = Ecto.Changeset.put_change(changeset, :tags, values ++ [""])
    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("change", %{"group" => attrs}, socket) do
    changeset =
      Gateways.change_group(socket.assigns.group, attrs)
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"group" => attrs}, socket) do
    with {:ok, group} <-
           Gateways.update_group(socket.assigns.group, attrs, socket.assigns.subject) do
      socket = redirect(socket, to: ~p"/#{socket.assigns.account}/gateway_groups/#{group}")
      {:noreply, socket}
    else
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/gateway_groups"}>Gateway Instance Groups</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/gateway_groups/#{@group}"}>
        <%= @group.name_prefix %>
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/gateway_groups/#{@group}/edit"}>Edit</.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Editing Gateway Instance Group <code><%= @group.name_prefix %></code>
      </:title>
    </.header>

    <section class="bg-white dark:bg-gray-900">
      <div class="py-8 px-4 mx-auto max-w-2xl lg:py-16">
        <.form for={@form} phx-change={:change} phx-submit={:submit}>
          <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
            <div>
              <.input
                label="Name Prefix"
                field={@form[:name_prefix]}
                placeholder="Name of this Gateway Instance Group"
                required
              />
            </div>
            <div>
              <.input label="Tags" type="taglist" field={@form[:tags]} placeholder="Tag" />
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
