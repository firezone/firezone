defmodule Web.Settings.ApiClients.New do
  use Web, :live_view
  import Web.Settings.ApiClients.Components
  alias Domain.Actors

  def mount(_params, _session, socket) do
    if Domain.Accounts.rest_api_enabled?(socket.assigns.account) do
      changeset = Actors.new_actor(%{type: :api_client})

      socket =
        assign(socket,
          form: to_form(changeset),
          page_title: "New API Client"
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
      <.breadcrumb path={~p"/#{@account}/settings/api_clients/new"}>Add</.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>{@page_title}</:title>
      <:content>
        <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
          <h2 class="mb-4 text-xl text-neutral-900">
            API Client details
          </h2>
          <.flash kind={:error} flash={@flash} />
          <.form for={@form} phx-change={:change} phx-submit={:submit}>
            <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
              <.api_client_form form={@form} type={:api_client} subject={@subject} />
            </div>
            <.submit_button>
              Next: Add a token
            </.submit_button>
          </.form>
        </div>
      </:content>
    </.section>
    """
  end

  def handle_event("change", %{"actor" => attrs}, socket) do
    changeset =
      attrs
      |> Map.put("type", :api_client)
      |> Actors.new_actor()
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"actor" => attrs}, socket) do
    attrs =
      attrs
      |> Map.put("type", :api_client)

    with {:ok, actor} <-
           Actors.create_actor(
             socket.assigns.account,
             attrs,
             socket.assigns.subject
           ) do
      socket =
        push_navigate(socket,
          to: ~p"/#{socket.assigns.account}/settings/api_clients/#{actor}/new_token"
        )

      {:noreply, socket}
    else
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end
