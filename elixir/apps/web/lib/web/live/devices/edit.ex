defmodule Web.Devices.Edit do
  use Web, :live_view
  alias Domain.Devices

  def mount(%{"id" => id} = _params, _session, socket) do
    with {:ok, device} <- Devices.fetch_device_by_id(id, socket.assigns.subject) do
      changeset = Devices.change_device(device)
      {:ok, assign(socket, device: device, form: to_form(changeset))}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def handle_event("change", %{"device" => attrs}, socket) do
    changeset =
      Devices.change_device(socket.assigns.device, attrs)
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"device" => attrs}, socket) do
    with {:ok, device} <-
           Devices.update_device(socket.assigns.device, attrs, socket.assigns.subject) do
      socket = redirect(socket, to: ~p"/#{socket.assigns.account}/devices/#{device}")
      {:noreply, socket}
    else
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/devices"}>Devices</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/devices/#{@device}"}>
        <%= @device.name %>
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/devices/#{@device}/edit"}>
        Edit
      </.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Editing device <code>Engineering</code>
      </:title>
    </.header>
    <!-- Update Group -->
    <section class="bg-white dark:bg-gray-900">
      <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
        <h2 class="mb-4 text-xl font-bold text-gray-900 dark:text-white">Edit device details</h2>
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
