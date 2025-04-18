defmodule Web.Settings.DirectoryProviders.Okta.Edit do
  use Web, :live_view
  alias Domain.Crypto
  alias Domain.Directories
  alias Domain.Directories.Okta.Config

  def mount(_params, _session, socket) do
    with {:ok, directory_provider} <- Directories.fetch_provider_by_account_and_type(socket.assigns.account, :okta) do
      private_key = directory_provider.config["private_key"]
      public_key = Crypto.JWK.public_key(private_key)
      changeset = Config.Changeset.changeset(directory_provider.config)

      {:ok, assign(socket,
        form: to_form(changeset),
        directory_provider: directory_provider,
        page_title: "Edit Directory Provider: Okta",
        public_key: public_key
      )}
    else
      _ ->
        raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/settings/directory_providers"}>
        Directory Provider Settings
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/settings/directory_providers/okta/edit"}>
        Edit Okta Provider
      </.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>{@page_title}</:title>
      <:help>
        Connect your Okta directory to sync users, groups, and memberships into Firezone.
      </:help>
      <:content>
        <div class="max-w-2xl px-4 py-8 mx-auto lg:py-12">
          <.form for={@form} phx-submit={:submit}>
            <div class="mb-4">
              <.input
                label="Client ID"
                autocomplete="off"
                field={@form[:client_id]}
                placeholder="Client ID for the Okta application"
                required
              />
              <p class="mt-2 text-xs text-neutral-500">
                The Client ID for the Okta application you created.
              </p>
            </div>
            <div class="mb-4">
              <p class="text-sm text-neutral-900 mb-2">
                Copy and paste the below public key into the Okta application:
              </p>
              <.code_block
                id="public-key"
                class="w-full text-xs whitespace-pre-line rounded"
                phx-no-format
              >{Jason.Formatter.pretty_print(@public_key)}</.code_block>
            </div>
            <div class="mb-4">
              <.input
                label="Okta Domain"
                autocomplete="off"
                field={@form[:okta_domain]}
                placeholder="company.okta.com"
                required
              />
              <p class="mt-2 text-xs text-neutral-500">
                Your organization's unique Okta domain. See
                <.link
                  class={link_style()}
                  target="_blank"
                  href="https://developer.okta.com/docs/guides/find-your-domain/main/"
                >
                  the Okta documentation
                </.link>
                for how to find this.
              </p>
            </div>
            <div>
              <.submit_button>
                Save
              </.submit_button>
            </div>
          </.form>
        </div>
      </:content>
    </.section>
    """
  end

  def handle_event("submit", attrs, socket) do
    provider_attrs = %{
      "config" => attrs["config"]
    }

    case Directories.update_provider_config(socket.assigns.directory_provider, provider_attrs) do
      {:ok, _provider} ->
        socket =
          socket
          |> put_flash(:info, "Okta directory provider updated successfully.")
          |> push_navigate(to: ~p"/#{socket.assigns.account}/settings/directory_providers")

        {:noreply, socket}

      {:error, provider_changeset} ->
        config_changeset = provider_changeset.changes.config

        socket =
          socket
          |> assign(form: to_form(config_changeset))
          |> put_flash(:error, "Failed to update Okta directory provider.")

        {:noreply, socket}
    end
  end
end
