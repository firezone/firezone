defmodule Web.Policies.Show do
  use Web, :live_view
  import Web.Policies.Components
  alias Domain.{Accounts, Policies, Flows, Auth}

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, policy} <-
           Policies.fetch_policy_by_id_or_persistent_id(id, socket.assigns.subject,
             preload: [
               actor_group: [:provider],
               resource: [],
               created_by_identity: :actor,
               created_by_actor: [],
               replaced_by_policy: [:actor_group, :resource],
               replaces_policy: [:actor_group, :resource]
             ]
           ) do
      providers = Auth.all_active_providers_for_account!(socket.assigns.account)

      if connected?(socket) do
        :ok = Policies.subscribe_to_events_for_policy(policy)
      end

      socket =
        assign(socket,
          page_title: "Policy #{policy.id}",
          policy: policy,
          providers: providers,
          flow_activities_enabled?: Accounts.flow_activities_enabled?(socket.assigns.account)
        )
        |> assign_live_table("flows",
          query_module: Flows.Flow.Query,
          sortable_fields: [],
          hide_filters: [:expiration],
          callback: &handle_flows_update!/2
        )

      {:ok, socket}
    else
      _other -> raise Web.LiveErrors.NotFoundError
    end
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)
    {:noreply, socket}
  end

  def handle_flows_update!(socket, list_opts) do
    list_opts =
      Keyword.put(list_opts, :preload,
        client: [:actor],
        gateway: [:group]
      )

    with {:ok, flows, metadata} <-
           Flows.list_flows_for(socket.assigns.policy, socket.assigns.subject, list_opts) do
      {:ok,
       assign(socket,
         flows: flows,
         flows_metadata: metadata
       )}
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/policies"}>Policies</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/policies/#{@policy}"}>
        <.policy_name policy={@policy} />
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        <.policy_name policy={@policy} />
        <span :if={not is_nil(@policy.disabled_at)} class="text-primary-600">(disabled)</span>
        <span
          :if={not is_nil(@policy.deleted_at) and is_nil(@policy.replaced_by_policy_id)}
          }
          class="text-red-600"
        >
          (deleted)
        </span>
        <span :if={not is_nil(@policy.replaced_by_policy_id)} class={["text-red-500"]}>
          (replaced)
        </span>
      </:title>
      <:action :if={is_nil(@policy.deleted_at)}>
        <.edit_button navigate={~p"/#{@account}/policies/#{@policy}/edit"}>
          Edit Policy
        </.edit_button>
      </:action>
      <:action :if={is_nil(@policy.deleted_at)}>
        <.button_with_confirmation
          :if={is_nil(@policy.disabled_at)}
          id="disable"
          style="warning"
          icon="hero-lock-closed"
          on_confirm="disable"
        >
          <:dialog_title>Confirm disabling the Policy</:dialog_title>
          <:dialog_content>
            Are you sure you want to disable this policy?
            This will <strong>immediately</strong>
            revoke all access granted by it. Keep in mind, other policies may still grant access to the same resource.
          </:dialog_content>
          <:dialog_confirm_button>
            Disable
          </:dialog_confirm_button>
          <:dialog_cancel_button>
            Cancel
          </:dialog_cancel_button>
          Disable
        </.button_with_confirmation>
        <.button_with_confirmation
          :if={not is_nil(@policy.disabled_at)}
          id="enable"
          style="warning"
          confirm_style="primary"
          icon="hero-lock-open"
          on_confirm="enable"
        >
          <:dialog_title>Confirm enabling the Policy</:dialog_title>
          <:dialog_content>
            Are you sure you want to enable this policy?
            This will <strong>immediately</strong>
            grant access to the specified resource to all members of the given group.
          </:dialog_content>
          <:dialog_confirm_button>
            Enable
          </:dialog_confirm_button>
          <:dialog_cancel_button>
            Cancel
          </:dialog_cancel_button>
          Enable
        </.button_with_confirmation>
      </:action>
      <:content>
        <.vertical_table id="policy">
          <.vertical_table_row>
            <:label>
              ID
            </:label>
            <:value>
              <%= @policy.id %>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row :if={not is_nil(@policy.deleted_at)}>
            <:label>
              Persistent ID
            </:label>
            <:value>
              <%= @policy.persistent_id %>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row :if={
            not is_nil(@policy.deleted_at) and not is_nil(@policy.replaced_by_policy)
          }>
            <:label>
              Replaced by Policy
            </:label>
            <:value>
              <.link
                navigate={~p"/#{@account}/policies/#{@policy.replaced_by_policy}"}
                class={["text-accent-600"] ++ link_style()}
              >
                <.policy_name policy={@policy.replaced_by_policy} />
              </.link>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row :if={
            not is_nil(@policy.deleted_at) and not is_nil(@policy.replaces_policy)
          }>
            <:label>
              Replaced Policy
            </:label>
            <:value>
              <.link
                navigate={~p"/#{@account}/policies/#{@policy.replaces_policy}"}
                class={["text-accent-600"] ++ link_style()}
              >
                <.policy_name policy={@policy.replaces_policy} />
              </.link>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>
              Group
            </:label>
            <:value>
              <.group account={@account} group={@policy.actor_group} />
              <span :if={not is_nil(@policy.actor_group.deleted_at)} class="text-red-600">
                (deleted)
              </span>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>
              Resource
            </:label>
            <:value>
              <.link navigate={~p"/#{@account}/resources/#{@policy.resource_id}"} class={link_style()}>
                <%= @policy.resource.name %>
              </.link>
              <span :if={not is_nil(@policy.resource.deleted_at)} class="text-red-600">
                (deleted)
              </span>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row :if={@policy.conditions != []}>
            <:label>
              Conditions
            </:label>
            <:value>
              <.conditions providers={@providers} conditions={@policy.conditions} />
            </:value>
          </.vertical_table_row>
          <.vertical_table_row :if={@policy.description}>
            <:label>
              Description
            </:label>
            <:value>
              <span class="whitespace-pre" phx-no-format><%= @policy.description %></span>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>
              Created
            </:label>
            <:value>
              <.created_by account={@account} schema={@policy} />
            </:value>
          </.vertical_table_row>
        </.vertical_table>
      </:content>
    </.section>

    <.section>
      <:title>Recent Connections</:title>
      <:help>
        Recent connections opened by Actors to access the Resources governed by this Policy.
      </:help>
      <:content>
        <.live_table
          id="flows"
          rows={@flows}
          row_id={&"flows-#{&1.id}"}
          filters={@filters_by_table_id["flows"]}
          filter={@filter_form_by_table_id["flows"]}
          ordered_by={@order_by_table_id["flows"]}
          metadata={@flows_metadata}
        >
          <:col :let={flow} label="authorized">
            <.relative_datetime datetime={flow.inserted_at} />
          </:col>
          <:col :let={flow} label="client, actor" class="w-3/12">
            <.link navigate={~p"/#{@account}/clients/#{flow.client_id}"} class={link_style()}>
              <%= flow.client.name %>
            </.link>
            owned by
            <.link navigate={~p"/#{@account}/actors/#{flow.client.actor_id}"} class={link_style()}>
              <%= flow.client.actor.name %>
            </.link>
            <%= flow.client_remote_ip %>
          </:col>
          <:col :let={flow} label="gateway" class="w-3/12">
            <.link navigate={~p"/#{@account}/gateways/#{flow.gateway_id}"} class={link_style()}>
              <%= flow.gateway.group.name %>-<%= flow.gateway.name %>
            </.link>
            <br />
            <code class="text-xs"><%= flow.gateway_remote_ip %></code>
          </:col>
          <:col :let={flow} :if={@flow_activities_enabled?} label="activity">
            <.link navigate={~p"/#{@account}/flows/#{flow.id}"} class={link_style()}>
              Show
            </.link>
          </:col>
          <:empty>
            <div class="text-center text-neutral-500 p-4">No activity to display.</div>
          </:empty>
        </.live_table>
      </:content>
    </.section>

    <.danger_zone :if={is_nil(@policy.deleted_at)}>
      <:action>
        <.button_with_confirmation
          id="delete_policy"
          style="danger"
          icon="hero-trash-solid"
          on_confirm="delete"
          on_confirm_id={@policy.id}
        >
          <:dialog_title>Confirm deletion of Policy</:dialog_title>
          <:dialog_content>
            Are you sure you want to delete this Policy? All sessions authorized by it will be expired.
          </:dialog_content>
          <:dialog_confirm_button>
            Delete Policy
          </:dialog_confirm_button>
          <:dialog_cancel_button>
            Cancel
          </:dialog_cancel_button>
          Delete Policy
        </.button_with_confirmation>
      </:action>
    </.danger_zone>
    """
  end

  def handle_info({_action, _policy_id}, socket) do
    {:ok, policy} =
      Policies.fetch_policy_by_id_or_persistent_id(
        socket.assigns.policy.id,
        socket.assigns.subject,
        preload: [
          actor_group: [:provider],
          resource: [],
          created_by_identity: :actor,
          replaced_by_policy: [:actor_group, :resource],
          replaces_policy: [:actor_group, :resource]
        ]
      )

    {:noreply, assign(socket, policy: policy)}
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"],
    do: handle_live_table_event(event, params, socket)

  def handle_event("disable", _params, socket) do
    {:ok, policy} = Policies.disable_policy(socket.assigns.policy, socket.assigns.subject)

    policy = %{
      policy
      | actor_group: socket.assigns.policy.actor_group,
        resource: socket.assigns.policy.resource,
        created_by_identity: socket.assigns.policy.created_by_identity,
        replaced_by_policy: socket.assigns.policy.replaced_by_policy,
        replaces_policy: socket.assigns.policy.replaces_policy
    }

    {:noreply, assign(socket, policy: policy)}
  end

  def handle_event("enable", _params, socket) do
    {:ok, policy} = Policies.enable_policy(socket.assigns.policy, socket.assigns.subject)

    policy = %{
      policy
      | actor_group: socket.assigns.policy.actor_group,
        resource: socket.assigns.policy.resource,
        created_by_identity: socket.assigns.policy.created_by_identity,
        replaced_by_policy: socket.assigns.policy.replaced_by_policy,
        replaces_policy: socket.assigns.policy.replaces_policy
    }

    {:noreply, assign(socket, policy: policy)}
  end

  def handle_event("delete", _params, socket) do
    {:ok, _} = Policies.delete_policy(socket.assigns.policy, socket.assigns.subject)
    {:noreply, push_navigate(socket, to: ~p"/#{socket.assigns.account}/policies")}
  end
end
