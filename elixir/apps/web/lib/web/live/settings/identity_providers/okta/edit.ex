defmodule Web.Settings.IdentityProviders.Okta.Edit do
  use Web, :live_view
  import Web.Settings.IdentityProviders.Okta.Components
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
      <.breadcrumb path={~p"/#{@account}/settings/identity_providers/okta/#{@form.data}/edit"}>
        Edit <%= # {@form.data.name} %>
      </.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>
        Edit Identity Provider <%= @form.data.name %>
      </:title>
      <:content>
        <.provider_form account={@account} id={@form.data.id} form={@form} />
      </:content>
    </.section>
    """
  end

  def handle_event("change", %{"provider" => attrs}, socket) do
    attrs =
      attrs
      |> put_discovery_document_uri()

    changeset =
      Auth.change_provider(socket.assigns.provider, attrs)
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"provider" => attrs}, socket) do
    attrs =
      attrs
      |> Map.update("adapter_config", %{}, &put_api_base_url/1)

    with {:ok, provider} <-
           Auth.update_provider(socket.assigns.provider, attrs, socket.assigns.subject) do
      socket =
        push_navigate(socket,
          to:
            ~p"/#{socket.assigns.account.id}/settings/identity_providers/okta/#{provider}/redirect"
        )

      {:noreply, socket}
    else
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
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
