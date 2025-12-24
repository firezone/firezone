defmodule Web.Settings.ApiClients.Edit do
  use Web, :live_view
  import Web.Settings.ApiClients.Components
  import Ecto.Changeset

  alias __MODULE__.DB

  def mount(%{"id" => id}, _session, socket) do
    if Domain.Account.rest_api_enabled?(socket.assigns.account) do
      actor = DB.get_api_client!(id, socket.assigns.subject)
      changeset = changeset(actor, %{})

      socket =
        assign(socket,
          actor: actor,
          form: to_form(changeset),
          page_title: "Edit #{actor.name}"
        )

      {:ok, socket, temporary_assigns: [form: %Phoenix.HTML.Form{}]}
    else
      {:ok, push_navigate(socket, to: ~p"/#{socket.assigns.account}/settings/api_clients/beta")}
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/settings/api_clients"}>API Clients</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/settings/api_clients/#{@actor}"}>
        {@actor.name}
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/settings/api_clients/#{@actor}/edit"}>Edit</.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>{@page_title}</:title>
      <:content>
        <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
          <h2 class="mb-4 text-xl text-neutral-900">
            Edit API Client
          </h2>
          <.flash kind={:error} flash={@flash} />
          <.form for={@form} phx-change={:change} phx-submit={:submit}>
            <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
              <.api_client_form form={@form} type={:api_client} subject={@subject} />
            </div>
            <.submit_button>
              Update
            </.submit_button>
          </.form>
        </div>
      </:content>
    </.section>
    """
  end

  def handle_event("change", %{"actor" => attrs}, socket) do
    changeset =
      changeset(socket.assigns.actor, attrs)
      |> Map.put(:action, :update)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"actor" => attrs}, socket) do
    changeset = changeset(socket.assigns.actor, attrs)

    with {:ok, actor} <- DB.update_api_client(changeset, socket.assigns.subject) do
      socket =
        push_navigate(socket, to: ~p"/#{socket.assigns.account}/settings/api_clients/#{actor}")

      {:noreply, socket}
    else
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp changeset(actor, attrs) do
    actor
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
  end

  defmodule DB do
    import Ecto.Query
    alias Domain.Safe

    def get_api_client!(id, subject) do
      from(a in Domain.Actor,
        where: a.id == ^id,
        where: a.type == :api_client
      )
      |> Safe.scoped(subject)
      |> Safe.one!()
    end

    def update_api_client(changeset, subject) do
      Safe.scoped(changeset, subject) |> Safe.update()
    end
  end
end
