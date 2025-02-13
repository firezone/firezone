defmodule Web.Flows.Show do
  use Web, :live_view
  import Web.Policies.Components
  alias Domain.{Accounts, Flows}

  def mount(%{"id" => id}, _session, socket) do
    with true <- Accounts.flow_activities_enabled?(socket.assigns.account),
         {:ok, flow} <-
           Flows.fetch_flow_by_id(id, socket.assigns.subject,
             preload: [
               policy: [:resource, :actor_group],
               client: [],
               gateway: [:group],
               resource: []
             ]
           ) do
      last_used_connectivity_type = get_last_used_connectivity_type(flow, socket.assigns.subject)

      socket =
        socket
        |> assign(
          page_title: "Flow #{flow.id}",
          flow: flow,
          last_used_connectivity_type: last_used_connectivity_type
        )
        |> assign_live_table("activities",
          query_module: Flows.Activity.Query,
          sortable_fields: [],
          callback: &handle_activities_update!/2
        )

      {:ok, socket}
    else
      _other -> raise Web.LiveErrors.NotFoundError
    end
  end

  defp get_last_used_connectivity_type(flow, subject) do
    case Flows.fetch_last_activity_for(flow, subject) do
      {:ok, activity} -> to_string(activity.connectivity_type)
      _other -> "N/A"
    end
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)
    {:noreply, socket}
  end

  def handle_activities_update!(socket, list_opts) do
    with {:ok, activities, metadata} <-
           Flows.list_flow_activities_for(socket.assigns.flow, socket.assigns.subject, list_opts) do
      {:ok,
       assign(socket,
         activities: activities,
         activities_metadata: metadata
       )}
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb>Flows</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/flows/#{@flow.id}"}>
        {@flow.client.name} flow
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Flow for: <code>{@flow.client.name}</code>
      </:title>
      <:action>
        <.button
          navigate={~p"/#{@account}/flows/#{@flow}/activities.csv"}
          icon="hero-arrow-down-on-square"
        >
          Export to CSV
        </.button>
      </:action>
      <:content flash={@flash}>
        <.vertical_table id="flow">
          <.vertical_table_row>
            <:label>Authorized At</:label>
            <:value>
              <.relative_datetime datetime={@flow.inserted_at} />
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Expires At</:label>
            <:value>
              <.relative_datetime datetime={@flow.expires_at} />
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Policy</:label>
            <:value>
              <.link navigate={~p"/#{@account}/policies/#{@flow.policy_id}"} class={link_style()}>
                <.policy_name policy={@flow.policy} />
              </.link>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Client</:label>
            <:value>
              <.link navigate={~p"/#{@account}/clients/#{@flow.client_id}"} class={link_style()}>
                {@flow.client.name}
              </.link>
              <div>Remote IP: {@flow.client_remote_ip}</div>
              <div>User Agent: {@flow.client_user_agent}</div>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Gateway</:label>
            <:value>
              <.link navigate={~p"/#{@account}/gateways/#{@flow.gateway_id}"} class={link_style()}>
                {@flow.gateway.group.name}-{@flow.gateway.name}
              </.link>
              <div>
                Remote IP: {@flow.gateway_remote_ip}
              </div>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Resource</:label>
            <:value>
              <.link navigate={~p"/#{@account}/resources/#{@flow.resource_id}"} class={link_style()}>
                {@flow.resource.name}
              </.link>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Connectivity Type</:label>
            <:value>
              {@last_used_connectivity_type}
            </:value>
          </.vertical_table_row>
        </.vertical_table>
      </:content>
    </.section>

    <.section>
      <:title>Metrics</:title>
      <:help>
        Pre-aggregated metrics for this flow.
      </:help>
      <:content>
        <.live_table
          id="activities"
          rows={@activities}
          row_id={&"activities-#{&1.id}"}
          filters={@filters_by_table_id["activities"]}
          filter={@filter_form_by_table_id["activities"]}
          ordered_by={@order_by_table_id["activities"]}
          metadata={@activities_metadata}
        >
          <:col :let={activity} label="started">
            <.relative_datetime datetime={activity.window_started_at} />
          </:col>
          <:col :let={activity} label="ended">
            <.relative_datetime datetime={activity.window_ended_at} />
          </:col>
          <:col :let={activity} label="destination">
            {activity.destination}
          </:col>
          <:col :let={activity} label="connectivity type">
            {activity.connectivity_type}
          </:col>
          <:col :let={activity} label="rx">
            {Sizeable.filesize(activity.rx_bytes)}
          </:col>
          <:col :let={activity} label="tx">
            {Sizeable.filesize(activity.tx_bytes)}
          </:col>
          <:col :let={activity} label="blocked tx">
            {Sizeable.filesize(activity.blocked_tx_bytes)}
          </:col>
          <:empty>
            <div class="text-center text-neutral-500 p-4">No metrics to display.</div>
          </:empty>
        </.live_table>
      </:content>
    </.section>
    """
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"],
    do: handle_live_table_event(event, params, socket)
end
