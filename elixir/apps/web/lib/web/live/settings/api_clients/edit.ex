defmodule Web.Settings.ApiClients.Edit do
  use Web, :live_view
  import Web.Settings.ApiClients.Components
  alias Domain.Actors

  def mount(%{"id" => id}, _session, socket) do
    if Domain.Accounts.rest_api_enabled?(socket.assigns.account) do
      with {:ok, actor} <- Actors.fetch_actor_by_id(id, socket.assigns.subject, preload: []),
           nil <- actor.deleted_at do
        changeset = Actors.change_actor(actor)

        socket =
          assign(socket,
            actor: actor,
            form: to_form(changeset),
            page_title: "Edit #{actor.name}"
          )

        {:ok, socket, temporary_assigns: [form: %Phoenix.HTML.Form{}]}
      else
        _other -> raise Web.LiveErrors.NotFoundError
      end
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
    attrs =
      attrs
      |> Map.put("type", :api_client)

    changeset =
      Actors.change_actor(socket.assigns.actor, attrs)
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"actor" => attrs}, socket) do
    attrs =
      attrs
      |> Map.put("type", :api_client)

    with {:ok, actor} <- Actors.update_actor(socket.assigns.actor, attrs, socket.assigns.subject) do
      socket =
        push_navigate(socket, to: ~p"/#{socket.assigns.account}/settings/api_clients/#{actor}")

      {:noreply, socket}
    else
      {:error, :unauthorized} ->
        {:noreply,
         put_flash(socket, :error, "You don't have permissions to perform this action.")}

      {:error, {:unauthorized, _context}} ->
        {:noreply,
         put_flash(socket, :error, "You don't have permissions to perform this action.")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end
