defmodule Web.Settings.IdentityProviders.JumpCloud.New do
  use Web, :live_view
  import Web.Settings.IdentityProviders.JumpCloud.Components
  alias Domain.Auth

  def mount(_params, _session, socket) do
    id = Ecto.UUID.generate()

    changeset =
      Auth.new_provider(socket.assigns.account, %{
        name: "JumpCloud",
        adapter: :jumpcloud,
        adapter_config: %{}
      })

    socket =
      assign(socket,
        id: id,
        form: to_form(changeset),
        page_title: "New Identity Provider: JumpCloud"
      )

    {:ok, socket, temporary_assigns: [form: %Phoenix.HTML.Form{}]}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/settings/identity_providers"}>
        Identity Providers Settings
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/settings/identity_providers/new"}>
        Create Identity Provider
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/settings/identity_providers/jumpcloud/new"}>
        JumpCloud
      </.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>{@page_title}</:title>
      <:help>
        For a more detailed guide on setting up Firezone with JumpCloud, please <.link
          href="https://www.firezone.dev/kb/authenticate/jumpcloud"
          class={link_style()}
        >refer to our documentation</.link>.
      </:help>
      <:content>
        <.provider_form account={@account} id={@id} form={@form} />
      </:content>
    </.section>
    """
  end

  def handle_event("change", %{"provider" => attrs}, socket) do
    attrs = Map.put(attrs, "adapter", :jumpcloud)

    changeset =
      Auth.new_provider(socket.assigns.account, attrs)
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"provider" => attrs}, socket) do
    attrs =
      attrs
      |> Map.put("id", socket.assigns.id)
      |> Map.put("adapter", :jumpcloud)
      |> update_adapter_config("workos_org", %{})
      # We create provider in a disabled state because we need to write access token for it first
      |> Map.put("adapter_state", %{status: "pending_access_token"})
      |> Map.put("disabled_at", DateTime.utc_now())

    with {:ok, provider} <-
           Auth.create_provider(socket.assigns.account, attrs, socket.assigns.subject) do
      socket =
        push_navigate(socket,
          to:
            ~p"/#{socket.assigns.account.id}/settings/identity_providers/jumpcloud/#{provider}/redirect"
        )

      {:noreply, socket}
    else
      {:error, changeset} ->
        # Here we can have an insert conflict error, which will be returned without embedded fields information,
        # this will crash `.inputs_for` component in the template, so we need to handle it here.
        new_changeset =
          Auth.new_provider(socket.assigns.account, attrs)
          |> Map.put(:action, :insert)

        {:noreply, assign(socket, form: to_form(%{new_changeset | errors: changeset.errors}))}
    end
  end

  defp update_adapter_config(attrs, key, value) do
    updated_config =
      attrs["adapter_config"]
      |> Map.put_new(key, value)

    Map.put(attrs, "adapter_config", updated_config)
  end
end
