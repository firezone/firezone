defmodule Web.Settings.IdentityProviders.Okta.New do
  use Web, :live_view
  import Web.Settings.IdentityProviders.Okta.Components
  alias Domain.Auth

  def mount(_params, _session, socket) do
    id = Ecto.UUID.generate()

    changeset =
      Auth.new_provider(socket.assigns.account, %{
        name: "Okta",
        adapter: :okta,
        adapter_config: %{}
      })

    socket =
      assign(socket,
        id: id,
        form: to_form(changeset),
        page_title: "New Identity Provider"
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
      <.breadcrumb path={~p"/#{@account}/settings/identity_providers/okta/new"}>
        Okta
      </.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>
        Add a new Okta Identity Provider
      </:title>
      <:help>
        For a more detailed guide on setting up Firezone with Okta, please <.link class={link_style()}>refer to our documentation</.link>.
      </:help>
      <:content>
        <.provider_form account={@account} id={@id} form={@form} />
      </:content>
    </.section>
    """
  end

  def handle_event("change", %{"provider" => attrs}, socket) do
    attrs =
      attrs
      |> Map.put("adapter", :okta)
      |> put_discovery_document_uri()

    changeset =
      Auth.new_provider(socket.assigns.account, attrs)
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"provider" => attrs}, socket) do
    attrs =
      attrs
      |> Map.update("adapter_config", %{}, &put_api_base_url/1)
      |> Map.put("id", socket.assigns.id)
      |> Map.put("adapter", :okta)
      # We create provider in a disabled state because we need to write access token for it first
      |> Map.put("adapter_state", %{status: "pending_access_token"})
      |> Map.put("disabled_at", DateTime.utc_now())

    with {:ok, provider} <-
           Auth.create_provider(socket.assigns.account, attrs, socket.assigns.subject) do
      socket =
        push_navigate(socket,
          to:
            ~p"/#{socket.assigns.account.id}/settings/identity_providers/okta/#{provider}/redirect"
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

  defp put_api_base_url(adapter_config) do
    uri = URI.parse(adapter_config["discovery_document_uri"])
    Map.put(adapter_config, "api_base_url", "#{uri.scheme}://#{uri.host}")
  end

  defp put_discovery_document_uri(attrs) do
    config = attrs["adapter_config"]

    oidc_uri =
      String.replace_suffix(
        config["oauth_uri"],
        "oauth-authorization-server",
        "openid-configuration"
      )

    config = Map.put(config, "discovery_document_uri", oidc_uri)

    Map.put(attrs, "adapter_config", config)
  end
end
