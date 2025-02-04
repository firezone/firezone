defmodule Web.Settings.IdentityProviders.GoogleWorkspace.Edit do
  use Web, :live_view
  import Web.Settings.IdentityProviders.GoogleWorkspace.Components
  alias Domain.Auth

  def mount(%{"provider_id" => provider_id}, _session, socket) do
    with {:ok, provider} <- Domain.Auth.fetch_provider_by_id(provider_id, socket.assigns.subject) do
      changeset = Auth.change_provider(provider)

      socket =
        assign(socket,
          provider: provider,
          form: to_form(changeset),
          page_title: "Edit #{provider.name}"
        )

      {:ok, socket, temporary_assigns: [form: %Phoenix.HTML.Form{}]}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/settings/identity_providers"}>
        Identity Providers Settings
      </.breadcrumb>
      <.breadcrumb path={
        ~p"/#{@account}/settings/identity_providers/google_workspace/#{@form.data}/edit"
      }>
        Edit
      </.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>
        Edit Identity Provider {@form.data.name}
      </:title>
      <:content>
        <.provider_form account={@account} id={@form.data.id} form={@form} />
      </:content>
    </.section>
    """
  end

  def handle_event("change", %{"provider" => attrs}, socket) do
    attrs = map_provider_form_attrs(attrs)

    changeset =
      Auth.change_provider(socket.assigns.provider, attrs)
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"provider" => attrs}, socket) do
    attrs = map_provider_form_attrs(attrs)

    with {:ok, provider} <-
           Auth.update_provider(socket.assigns.provider, attrs, socket.assigns.subject) do
      socket =
        push_navigate(socket,
          to:
            ~p"/#{socket.assigns.account.id}/settings/identity_providers/google_workspace/#{provider}/redirect"
        )

      {:noreply, socket}
    else
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end
