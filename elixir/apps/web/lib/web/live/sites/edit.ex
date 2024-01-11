defmodule Web.Sites.Edit do
  use Web, :live_view
  import Web.Sites.Components
  alias Domain.Gateways

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, group} <- Gateways.fetch_group_by_id(id, socket.assigns.subject),
         nil <- group.deleted_at do
      changeset = Gateways.change_group(group)

      socket =
        assign(socket, group: group, form: to_form(changeset), page_title: "Edit #{group.name}")

      {:ok, socket, temporary_assigns: [form: %Phoenix.HTML.Form{}]}
    else
      _other -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/sites"}>Sites</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/sites/#{@group}"}>
        <%= @group.name %>
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/sites/#{@group}/edit"}>Edit</.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>Edit Site: <code><%= @group.name %></code></:title>
      <:content>
        <div class="py-8 px-4 mx-auto max-w-2xl lg:py-16">
          <.form for={@form} phx-change={:change} phx-submit={:submit}>
            <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
              <div>
                <.input label="Name" field={@form[:name]} placeholder="Name of this Site" required />
              </div>
              <div>
                <p class="text-lg text-neutral-900 mb-2">
                  Data Routing -
                  <a
                    class={[link_style(), "text-sm"]}
                    href="https://www.firezone.dev/kb?utm_source=product"
                    target="_blank"
                  >
                    Read about routing in Firezone
                  </a>
                </p>
                <div>
                  <div>
                    <.input
                      id="routing-option-managed"
                      type="radio"
                      field={@form[:routing]}
                      value="managed"
                      label={pretty_print_routing(:managed)}
                      checked={@form[:routing].value == :managed}
                      required
                    >
                      <.badge
                        class="ml-2"
                        type="primary"
                        title="Feature available on the Enterprise plan"
                      >
                        ENTERPRISE
                      </.badge>
                    </.input>
                    <p class="ml-6 mb-4 text-sm text-neutral-500">
                      Firezone will route connections through our managed Relays only if a direct connection to a Gateway is not possible.
                      Firezone can never decrypt the contents of your traffic.
                    </p>
                  </div>
                  <div>
                    <.input
                      id="routing-option-stun-only"
                      type="radio"
                      field={@form[:routing]}
                      value="stun_only"
                      label={pretty_print_routing(:stun_only)}
                      checked={@form[:routing].value == :stun_only}
                      required
                    />
                    <p class="ml-6 mb-4 text-sm text-neutral-500">
                      Firezone will enforce direct connections to all Gateways in this Site. This could cause connectivity issues in rare cases.
                    </p>
                  </div>
                </div>
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

  def handle_event("change", %{"group" => attrs}, socket) do
    changeset =
      Gateways.change_group(socket.assigns.group, attrs)
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"group" => attrs}, socket) do
    with {:ok, group} <-
           Gateways.update_group(socket.assigns.group, attrs, socket.assigns.subject) do
      socket = push_navigate(socket, to: ~p"/#{socket.assigns.account}/sites/#{group}")
      {:noreply, socket}
    else
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end
