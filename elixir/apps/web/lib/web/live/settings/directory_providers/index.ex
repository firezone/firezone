defmodule Web.Settings.DirectoryProviders.Index do
  use Web, :live_view
  alias Domain.Directories

  def mount(_params, _session, socket) do
    with {:ok, directory_providers, _metadata} <-
           Directories.list_providers_for_account(socket.assigns.account) do
      {:ok,
       assign(socket,
         page_title: "Directory Providers",
         directory_providers: directory_providers
       )}
    else
      _ -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/settings/directory_providers"}>
        Directory Provider Settings
      </.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>
        Directory Providers
      </:title>
      <:action>
        <.docs_action path="/authenticate/directory_sync" />
      </:action>
      <:help>
        Directory providers sync your users and groups with an external source.
      </:help>
      <:content>
        <.flash_group flash={@flash} />

        <ul class="grid w-full gap-6 md:grid-cols-3">
          <li>
            <div class="block">
              <div class="w-full font-semibold mb-3">
                <.provider_icon adapter={:okta} class="w-5 h-5 mr-1" /> Okta
              </div>
              <div class="w-full text-sm">
                Sync users, groups, and memberships from your Okta directory.
              </div>
              <div :if={provider_created?(@directory_providers, :okta)}>
                <.link
                  class={link_style()}
                  navigate={~p"/#{@account}/settings/directory_providers/okta/edit"}
                >
                  Edit
                </.link>
              </div>
              <div :if={not provider_created?(@directory_providers, :okta)}>
                <.link
                  class={link_style()}
                  navigate={~p"/#{@account}/settings/directory_providers/okta/new"}
                >
                  Create
                </.link>
              </div>
            </div>
          </li>
        </ul>
      </:content>
    </.section>
    """
  end

  defp provider_created?(directory_providers, type) do
    Enum.any?(directory_providers, &(&1.type == type))
  end
end
