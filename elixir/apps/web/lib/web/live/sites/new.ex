defmodule Web.Sites.New do
  use Web, :live_view
  import Web.Sites.Components
  alias Domain.Gateways

  def mount(_params, _session, socket) do
    changeset = Gateways.new_group()
    {:ok, assign(socket, form: to_form(changeset))}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/sites"}>Sites</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/sites/new"}>Add</.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Add a new Site
      </:title>
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

            <div class="flex justify-end">
            <.submit_button>
              Create
            </.submit_button>
          </div>
          </.form>
        </div>
      </:content>
    </.section>
    """
  end

  def handle_event("change", %{"group" => attrs}, socket) do
    changeset =
      Gateways.new_group(attrs)
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"group" => attrs}, socket) do
    attrs = Map.put(attrs, "tokens", [%{}])

    with {:ok, group} <-
           Gateways.create_group(attrs, socket.assigns.subject) do
      {:noreply, push_navigate(socket, to: ~p"/#{socket.assigns.account}/sites/#{group}")}
    else
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end
