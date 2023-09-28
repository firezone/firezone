defmodule Web.Flows.Show do
  use Web, :live_view
  import Web.Policies.Components
  alias Domain.{Flows, Flows}

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, flow} <-
           Flows.fetch_flow_by_id(id, socket.assigns.subject,
             preload: [
               policy: [:resource, :actor_group],
               client: [],
               gateway: [:group],
               resource: []
             ]
           ),
         {:ok, activities} <-
           Flows.list_flow_activities_for(
             flow,
             flow.inserted_at,
             flow.expires_at,
             socket.assigns.subject
           ) do
      activities_by_destination = Enum.group_by(activities, & &1.destination)

      {:ok, socket,
       temporary_assigns: [
         flow: flow,
         starts_at: flow.inserted_at,
         ends_at: flow.expires_at,
         activities_by_destination: activities_by_destination
       ]}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  defp chart_series(activities) do
    {rx, tx} =
      Enum.reduce(activities, {[], []}, fn activity, {rx_acc, tx_txx} ->
        rx_bytes = Float.ceil(activity.rx_bytes / 1024 / 1024, 2)
        tx_bytes = Float.ceil(activity.tx_bytes / 1024 / 1024, 2)
        rx = %{x: activity.window_ended_at, y: rx_bytes}
        tx = %{x: activity.window_ended_at, y: tx_bytes}
        {rx_acc ++ [rx], tx_txx ++ [tx]}
      end)

    [
      %{
        name: "RX",
        data: rx,
        color: "#1A56DB"
      },
      %{
        name: "TX",
        data: tx,
        color: "#7E3AF2"
      }
    ]
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb>Flows</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/flows/#{@flow.id}"}>
        <%= @flow.client.name %> flow
      </.breadcrumb>
    </.breadcrumbs>

    <.page>
      <:title>
        Flow for: <code><%= @flow.client.name %></code>
      </:title>

      <:action
        navigate={~p"/#{@account}/flows/#{@flow}/activities.csv"}
        icon="hero-arrow-down-on-square"
      >
        Export to CSV
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
              <.link
                navigate={~p"/#{@account}/policies/#{@flow.policy_id}"}
                class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
              >
                <.policy_name policy={@flow.policy} />
              </.link>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Client</:label>
            <:value>
              <.link
                navigate={~p"/#{@account}/clients/#{@flow.client_id}"}
                class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
              >
                <%= @flow.client.name %>
              </.link>
              <div>Remote IP: <%= @flow.client_remote_ip %></div>
              <div>User Agent: <%= @flow.client_user_agent %></div>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Gateway</:label>
            <:value>
              <.link
                navigate={~p"/#{@account}/gateways/#{@flow.gateway_id}"}
                class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
              >
                <%= @flow.gateway.group.name_prefix %>-<%= @flow.gateway.name_suffix %>
              </.link>
              <div>
                Remote IP: <%= @flow.gateway_remote_ip %>
              </div>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Resource</:label>
            <:value>
              <.link
                navigate={~p"/#{@account}/resources/#{@flow.resource_id}"}
                class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
              >
                <%= @flow.resource.name %>
              </.link>
            </:value>
          </.vertical_table_row>
        </.vertical_table>

        <div
          :for={{destination, activities} <- @activities_by_destination}
          class="w-full bg-white rounded-lg shadow dark:bg-gray-800 p-4 md:p-6"
        >
          <div class="flex flex-row justify-between mb-5">
            <!--
          <div>
          <.date_range id={"activity-chart-#{Domain.Crypto.hash(:md5, to_string(destination))}"} />
          </div>
          -->
            <div class="text-l">
              Traffic to
              <span class="font-bold">
                <%= destination %>
              </span>
              in MB
            </div>
          </div>
          <.chart
            id={"activity-chart-#{Domain.Crypto.hash(:md5, to_string(destination))}"}
            options={
              %{
                chart: %{
                  height: "100px",
                  maxWidth: "100%",
                  type: "heatmap",
                  fontFamily: "Inter, sans-serif",
                  dropShadow: %{
                    enabled: false
                  },
                  toolbar: %{
                    show: false
                  }
                },
                tooltip: %{
                  enabled: true,
                  x: %{
                    show: false
                  }
                },
                dataLabels: %{
                  enabled: false
                },
                stroke: %{
                  width: 1,
                  curve: "smooth"
                },
                grid: %{
                  show: true,
                  strokeDashArray: 4,
                  padding: %{
                    left: 2,
                    right: 2,
                    top: -26
                  }
                },
                series: chart_series(activities),
                legend: %{
                  show: true
                },
                yaxis: %{
                  title: "MB"
                },
                xaxis: %{
                  type: "datetime",
                  title: "Date and Time",
                  tooltip: %{
                    enabled: true
                  },
                  labels: %{
                    show: true,
                    rotate: 45,
                    style: %{
                      fontFamily: "Inter, sans-serif",
                      cssClass: "text-xs font-normal fill-gray-500 dark:fill-gray-400"
                    },
                    format: "dd/MM HH:mm"
                  },
                  axisBorder: %{
                    show: false
                  },
                  axisTicks: %{
                    show: false
                  }
                }
              }
            }
          />
        </div>
      </:content>
    </.page>
    """
  end

  def date_range(assigns) do
    ~H"""
    <button
      id={"#{@id}-date_range-button"}
      data-dropdown-toggle={"#{@id}-date_range-dropdown"}
      data-dropdown-placement="bottom"
      type="button"
      class="px-3 py-2 inline-flex items-center text-sm font-medium text-gray-900 focus:outline-none bg-white rounded-lg border border-gray-200 hover:bg-gray-100 hover:text-blue-700 focus:z-10 focus:ring-4 focus:ring-gray-200 dark:focus:ring-gray-700 dark:bg-gray-800 dark:text-gray-400 dark:border-gray-600 dark:hover:text-white dark:hover:bg-gray-700"
    >
      Flow duration
      <svg
        class="w-2.5 h-2.5 ml-2.5"
        aria-hidden="true"
        xmlns="http://www.w3.org/2000/svg"
        fill="none"
        viewBox="0 0 10 6"
      >
        <path
          stroke="currentColor"
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke-width="2"
          d="m1 1 4 4 4-4"
        />
      </svg>
    </button>
    <div
      id={"#{@id}-date_range-dropdown"}
      class="z-10 hidden bg-white divide-y divide-gray-100 rounded-lg shadow w-44 dark:bg-gray-700"
    >
      <ul
        class="py-2 text-sm text-gray-700 dark:text-gray-200"
        aria-labelledby={"#{@id}-date_range-button"}
      >
        <li>
          <a
            href="#"
            class="block px-4 py-2 hover:bg-gray-100 dark:hover:bg-gray-600 dark:hover:text-white"
          >
            Flow duration
          </a>
        </li>
        <li>
          <a
            href="#"
            class="block px-4 py-2 hover:bg-gray-100 dark:hover:bg-gray-600 dark:hover:text-white"
          >
            Last 24 hours
          </a>
        </li>
        <li>
          <a
            href="#"
            class="block px-4 py-2 hover:bg-gray-100 dark:hover:bg-gray-600 dark:hover:text-white"
          >
            Last 7 days
          </a>
        </li>
        <li>
          <a
            href="#"
            class="block px-4 py-2 hover:bg-gray-100 dark:hover:bg-gray-600 dark:hover:text-white"
          >
            Last 30 days
          </a>
        </li>
      </ul>
    </div>
    """
  end
end
