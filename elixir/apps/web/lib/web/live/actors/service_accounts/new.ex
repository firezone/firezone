defmodule Web.Actors.ServiceAccounts.New do
  use Web, :live_view
  import Web.Actors.Components
  alias Domain.Actors

  def mount(_params, _session, socket) do
    with {:ok, groups} <- Actors.list_editable_groups(socket.assigns.subject, preload: :provider) do
      groups = Enum.filter(groups, &Actors.group_editable?/1)

      changeset = Actors.new_actor(%{type: :service_account})

      socket =
        assign(socket,
          groups: groups,
          form: to_form(changeset),
          page_title: "New Service Account"
        )

      {:ok, socket, temporary_assigns: [form: %Phoenix.HTML.Form{}]}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/actors"}>Actors</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/actors/new"}>Add</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/actors/service_accounts/new"}>Service Account</.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Create Actor
      </:title>
      <:content>
        <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
          <h2 class="mb-4 text-xl text-neutral-900">
            Create a Service Account
          </h2>
          <.flash kind={:error} flash={@flash} />
          <.form for={@form} phx-change={:change} phx-submit={:submit}>
            <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
              <.actor_form form={@form} type={:service_account} groups={@groups} subject={@subject} />
            </div>
            <.submit_button>
              Create
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
      |> map_actor_form_memberships_attr()
      |> Map.put("type", :service_account)
      |> Actors.new_actor()
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"actor" => attrs}, socket) do
    attrs =
      attrs
      |> Map.put("type", :service_account)
      |> map_actor_form_memberships_attr()

    with {:ok, actor} <-
           Actors.create_actor(
             socket.assigns.account,
             attrs,
             socket.assigns.subject
           ) do
      socket =
        push_navigate(socket,
          to: ~p"/#{socket.assigns.account}/actors/service_accounts/#{actor}/new_identity"
        )

      {:noreply, socket}
    else
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end
