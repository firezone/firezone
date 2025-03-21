defmodule Web.Settings.IdentityProviders.Mock.EditFilters do
  use Web, :live_view
  import Web.Settings.IdentityProviders.Components
  alias Domain.Auth

  def mount(%{"provider_id" => provider_id}, _session, socket) do
    with {:ok, provider} <- Auth.fetch_provider_by_id(provider_id, socket.assigns.subject) do
      # TODO: fetch these
      groups = [
        {"1", "Group 1"},
        {"2", "Group 2"},
        {"3", "Group 3"},
        {"4", "Group 4"},
        {"5", "Group 5"},
        {"6", "Group 6"},
        {"7", "Group 7"},
        {"8", "Group 8"},
        {"9", "Group 9"},
        {"10", "Group 10"}
      ]

      currently_included = MapSet.new(provider.included_groups)

      socket =
        assign(socket,
          provider: provider,
          currently_included: currently_included,
          to_include: %{},
          to_exclude: %{},
          fetched_groups: groups,
          page_title: "Edit #{provider.name} Group Filters",
          enabled: not is_nil(provider.group_filters_enabled_at)
        )

      {:ok, socket}
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
      <.breadcrumb path={~p"/#{@account}/settings/identity_providers/mock/#{@provider}/edit_filters"}>
        Edit Group Filters
      </.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>
        Edit Group Filters for Identity Provider {@provider.name}
      </:title>
      <:content>
        <.group_filters
          provider={@provider}
          currently_included={@currently_included}
          to_include={@to_include}
          to_exclude={@to_exclude}
          fetched_groups={@fetched_groups}
          enabled={@enabled}
        />
      </:content>
    </.section>
    """
  end

  # For group filters

  def handle_event(event, params, socket),
    do: handle_group_filters_event(event, params, socket)
end
