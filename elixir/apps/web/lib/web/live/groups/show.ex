defmodule Web.Groups.Show do
  use Web, :live_view
  import Web.Actors.Components
  alias Domain.{Actors, Policies}

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, group} <-
           Actors.fetch_group_by_id(id, socket.assigns.subject,
             preload: [
               provider: [],
               created_by_identity: [:actor],
               created_by_actor: []
             ]
           ) do
      socket =
        assign(socket,
          page_title: "Group #{group.name}",
          group: group
        )
        |> assign_live_table("actors",
          query_module: Actors.Actor.Query,
          sortable_fields: [
            {:actors, :name}
          ],
          enforce_filters: [
            {:group_id, group.id}
          ],
          hide_filters: [:type, :status, :provider_id],
          callback: &handle_actors_update!/2
        )
        |> assign_live_table("policies",
          query_module: Policies.Policy.Query,
          hide_filters: [
            :resource_id,
            :actor_group_name,
            :group_or_resource_name
          ],
          enforce_filters: [
            {:actor_group_id, group.id}
          ],
          sortable_fields: [],
          callback: &handle_policies_update!/2
        )

      {:ok, socket}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)
    {:noreply, socket}
  end

  def handle_actors_update!(socket, list_opts) do
    list_opts = Keyword.put(list_opts, :preload, [:last_seen_at, identities: :provider])

    with {:ok, actors, metadata} <- Actors.list_actors(socket.assigns.subject, list_opts) do
      {:ok,
       assign(socket,
         actors: actors,
         actors_metadata: metadata
       )}
    end
  end

  def handle_policies_update!(socket, list_opts) do
    list_opts = Keyword.put(list_opts, :preload, :resource)

    with {:ok, policies, metadata} <- Policies.list_policies(socket.assigns.subject, list_opts) do
      {:ok,
       assign(socket,
         policies: policies,
         policies_metadata: metadata
       )}
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/groups"}>Groups</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/groups/#{@group}"}>
        {@group.name}
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Group: <code>{@group.name}</code>
        <span :if={not is_nil(@group.deleted_at)} class="text-red-600">(deleted)</span>
      </:title>
      <:action :if={is_nil(@group.deleted_at)}>
        <.edit_button
          :if={Actors.group_editable?(@group)}
          navigate={~p"/#{@account}/groups/#{@group}/edit"}
        >
          Edit Group
        </.edit_button>
      </:action>
      <:content>
        <.flash
          :if={
            Actors.group_managed?(@group) and
              not Enum.any?(@group.membership_rules, &(&1 == %Actors.MembershipRule{operator: true}))
          }
          kind={:info}
        >
          This group is managed by Firezone and cannot be edited.
        </.flash>
        <.flash
          :if={
            Actors.group_managed?(@group) and
              Enum.any?(@group.membership_rules, &(&1 == %Actors.MembershipRule{operator: true}))
          }
          kind={:info}
        >
          <p>This Group contains all Users and cannot be edited.</p>
        </.flash>
        <.flash :if={Actors.group_synced?(@group)} kind={:info}>
          This group is synced from an external source and cannot be edited.
        </.flash>

        <.vertical_table id="group">
          <.vertical_table_row>
            <:label>Name</:label>
            <:value>{@group.name}</:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Created</:label>
            <:value><.created_by account={@account} schema={@group} /></:value>
          </.vertical_table_row>
        </.vertical_table>
      </:content>
    </.section>

    <.section>
      <:title>Actors</:title>
      <:action :if={is_nil(@group.deleted_at)}>
        <.edit_button
          :if={not Actors.group_synced?(@group) and not Actors.group_managed?(@group)}
          navigate={~p"/#{@account}/groups/#{@group}/edit_actors"}
        >
          Edit Actors
        </.edit_button>
      </:action>
      <:content>
        <.live_table
          id="actors"
          rows={@actors}
          filters={@filters_by_table_id["actors"]}
          filter={@filter_form_by_table_id["actors"]}
          ordered_by={@order_by_table_id["actors"]}
          metadata={@actors_metadata}
        >
          <:col :let={actor} label="name">
            <.actor_name_and_role account={@account} actor={actor} />
          </:col>
          <:col :let={actor} label="identities">
            <span class="flex flex-wrap gap-y-2">
              <.identity_identifier
                :for={identity <- actor.identities}
                account={@account}
                identity={identity}
              />
            </span>
          </:col>
          <:empty>
            <div class="flex justify-center text-center text-neutral-500 p-4">
              <div :if={not Actors.group_synced?(@group)} class="w-auto">
                <div class="pb-4">
                  There are no actors in this group.
                </div>
                <.edit_button
                  :if={not Actors.group_synced?(@group) and not Actors.group_managed?(@group)}
                  navigate={~p"/#{@account}/groups/#{@group}/edit_actors"}
                >
                  Edit Actors
                </.edit_button>
              </div>
            </div>
          </:empty>
        </.live_table>
      </:content>
    </.section>

    <.section>
      <:title>
        Policies
      </:title>
      <:action>
        <.add_button navigate={~p"/#{@account}/policies/new?actor_group_id=#{@group.id}"}>
          Add Policy
        </.add_button>
      </:action>
      <:content>
        <.live_table
          id="policies"
          rows={@policies}
          row_id={&"policies-#{&1.id}"}
          filters={@filters_by_table_id["policies"]}
          filter={@filter_form_by_table_id["policies"]}
          ordered_by={@order_by_table_id["policies"]}
          metadata={@policies_metadata}
        >
          <:col :let={policy} label="id">
            <.link class={link_style()} navigate={~p"/#{@account}/policies/#{policy}"}>
              {policy.id}
            </.link>
          </:col>
          <:col :let={policy} label="resource">
            <.link class={link_style()} navigate={~p"/#{@account}/resources/#{policy.resource_id}"}>
              {policy.resource.name}
            </.link>
          </:col>
          <:col :let={policy} label="status">
            <%= if is_nil(policy.deleted_at) do %>
              <%= if is_nil(policy.disabled_at) do %>
                Active
              <% else %>
                Disabled
              <% end %>
            <% else %>
              Deleted
            <% end %>
          </:col>
          <:empty>
            <div class="flex justify-center text-center text-neutral-500 p-4">
              <div class="pb-4 w-auto">
                No policies to display.
                <.link
                  class={[link_style()]}
                  navigate={~p"/#{@account}/policies/new?actor_group_id=#{@group.id}"}
                >
                  Add a policy
                </.link>
                to grant this Group access to Resources.
              </div>
            </div>
          </:empty>
        </.live_table>
      </:content>
    </.section>

    <.danger_zone :if={is_nil(@group.deleted_at) and Actors.group_editable?(@group)}>
      <:action>
        <.button_with_confirmation
          id="delete_group"
          style="danger"
          icon="hero-trash-solid"
          on_confirm="delete"
        >
          <:dialog_title>Confirm deletion of Group</:dialog_title>
          <:dialog_content>
            Are you sure you want to delete this Group and all related Policies?
          </:dialog_content>
          <:dialog_confirm_button>
            Delete Group
          </:dialog_confirm_button>
          <:dialog_cancel_button>
            Cancel
          </:dialog_cancel_button>
          Delete Group
        </.button_with_confirmation>
      </:action>
    </.danger_zone>
    """
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"],
    do: handle_live_table_event(event, params, socket)

  def handle_event("delete", _params, socket) do
    {:ok, _group} = Actors.delete_group(socket.assigns.group, socket.assigns.subject)
    {:noreply, push_navigate(socket, to: ~p"/#{socket.assigns.account}/groups")}
  end
end
