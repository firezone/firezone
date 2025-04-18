defmodule Web.Settings.DirectoryProviders.Okta.New do
  use Web, :live_view
  alias Domain.Crypto
  alias Domain.Directories
  alias Domain.Directories.Okta.Config

  def mount(_params, _session, socket) do
    changeset = Config.Changeset.new()

    keys =
      if connected?(socket) do
        private_key = Crypto.JWK.generate_private_key()
        public_key = Crypto.JWK.public_key(private_key)

        %{public_key: public_key, private_key: private_key}
      else
        %{public_key: "Loading...", private_key: nil}
      end

    {:ok,
     assign(socket,
       form: to_form(changeset),
       page_title: "New Directory Provider: Okta",
       public_key: keys.public_key,
       private_key: keys.private_key
     )}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/settings/directory_providers"}>
        Directory Provider Settings
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/settings/directory_providers/okta/new"}>
        New Okta Provider
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
    config =
      Map.merge(attrs["config"], %{
        "private_key" => socket.assigns.private_key
      })

    provider_attrs = %{
      "config" => config,
      "type" => :okta
    }

    case Directories.create_provider(socket.assigns.account, provider_attrs) do
      {:ok, _provider} ->
        socket =
          socket
          |> put_flash(:info, "Okta directory provider created successfully.")
          |> push_navigate(to: ~p"/#{socket.assigns.account}/settings/directory_providers")

        {:noreply, socket}

      {:error, provider_changeset} ->
        config_changeset = provider_changeset.changes.config

        socket =
          socket
          |> assign(form: to_form(config_changeset))
          |> put_flash(:error, "Failed to create Okta directory provider.")

        {:noreply, socket}
    end
  end
end
