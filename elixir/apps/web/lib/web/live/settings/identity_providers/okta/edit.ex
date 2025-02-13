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
    attrs =
      attrs
      |> Map.update("adapter_config", %{}, &put_discovery_document_uri/1)

    changeset =
      Auth.change_provider(socket.assigns.provider, attrs)
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"provider" => attrs}, socket) do
    attrs =
      attrs
      |> Map.update("adapter_config", %{}, &put_discovery_document_uri/1)
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
    api_base_url = create_api_base_url(adapter_config["okta_account_domain"])

    Map.put(adapter_config, "api_base_url", api_base_url)
  end

  defp put_discovery_document_uri(adapter_config) do
    api_base_url = create_api_base_url(adapter_config["okta_account_domain"])

    Map.put(
      adapter_config,
      "discovery_document_uri",
      "#{api_base_url}/.well-known/openid-configuration"
    )
  end

  # This is done for easier testing.  Production should only use 'https' and Okta domains,
  # but in dev and test there are times when putting an explicit URI is useful.
  if Mix.env() in [:dev, :test] do
    defp create_api_base_url(okta_account_domain) do
      uri = URI.parse(okta_account_domain)

      if uri.scheme, do: okta_account_domain, else: "https://#{okta_account_domain}"
    end
  else
    defp create_api_base_url(okta_account_domain) do
      "https://#{okta_account_domain}"
    end
  end
end
