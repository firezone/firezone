defmodule Web.Sites.New do
  use Web, :live_view
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
                <.input
                  label="Name Prefix"
                  field={@form[:name]}
                  placeholder="Name of this Site"
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
