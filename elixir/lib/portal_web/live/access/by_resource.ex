defmodule PortalWeb.Access.ByResource do
  use PortalWeb, :live_view

  alias PortalWeb.Access.Components
  alias __MODULE__.Database

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        page_title: "Policies by resource",
        resources: [],
        resources_metadata: %Portal.Repo.OffsetPaginator.Metadata{}
      )
      |> LiveTable.assign_live_table("resources",
        query_module: Database,
        sortable_fields: [],
        loader: &load_resources/2
      )

    {:ok, socket}
  end

  def handle_params(params, uri, socket) do
    {:noreply, LiveTable.handle_live_tables_params(socket, params, uri)}
  end

  def handle_event(event, params, socket)
      when event in ["paginate", "order_by", "filter", "reload", "table_row_click", "change_limit"],
      do: LiveTable.handle_live_table_event(event, params, socket)

  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full overflow-hidden">
      <Page.page_header>
        <:title>Policies by resource</:title>
        <:description>Who can reach each resource. Click a group to open its policy.</:description>
        <:action>
          <Form.button style="primary" icon="ri-add-line" navigate={~p"/#{@account}/policies/new"}>
            Add a policy
          </Form.button>
        </:action>
      </Page.page_header>

      <div class="flex-1 flex flex-col min-h-0 overflow-hidden">
        <LiveTable.live_table
          id="resources"
          loading={@loading_by_table_id["resources"]}
          query_error={@query_error_by_table_id["resources"]}
          rows={@resources}
          row_id={&"resources-#{&1.id}"}
          filters={@filters_by_table_id["resources"]}
          filter={@filter_form_by_table_id["resources"]}
          ordered_by={@order_by_table_id["resources"]}
          metadata={@resources_metadata}
          class="flex-1 min-h-0"
        >
          <:col :let={resource} label="Resource" class="w-1/4">
            <.link
              navigate={~p"/#{@account}/resources/#{resource.id}"}
              class="flex items-center gap-2 font-medium text-fg hover:underline"
            >
              <Core.icon name="ri-server-line" class="w-4 h-4 text-muted shrink-0" />
              <span class="truncate">{resource.name}</span>
            </.link>
            <div :if={resource.address} class="pl-6 font-mono text-xs text-muted truncate">
              {resource.address}
            </div>
          </:col>
          <:col :let={resource} label="Reached by">
            <div class="flex flex-wrap gap-1.5">
              <Components.chip
                :for={policy <- resource.policies}
                navigate={~p"/#{@account}/policies/#{policy.id}"}
                icon={if policy.direct?, do: "ri-user-line", else: "ri-group-line"}
                muted={policy.is_disabled}
                title={if policy.is_disabled, do: "Disabled policy", else: "Open the policy"}
              >
                {policy.label}
                <span :if={policy.is_disabled} class="text-faint">(disabled)</span>
              </Components.chip>
              <span :if={resource.policies == []} class="text-muted">Nobody</span>
            </div>
          </:col>
          <:col :let={resource} label="Total" class="w-24 text-right">
            <span class="tabular-nums text-muted">{length(resource.policies)}</span>
          </:col>
          <:empty>
            <div class="flex flex-col items-center gap-3 py-16">
              <Core.icon name="ri-server-line" class="w-6 h-6 text-faint" />
              <p class="text-sm text-muted">No resources yet.</p>
            </div>
          </:empty>
        </LiveTable.live_table>
      </div>
    </div>
    """
  end

  defp load_resources(subject, list_opts) do
    with {:ok, resources, metadata} <- Database.list_resources(subject, list_opts) do
      policies = Database.policies_by_resource(Enum.map(resources, & &1.id), subject)

      people =
        policies
        |> Map.values()
        |> List.flatten()
        |> Enum.filter(& &1.direct?)
        |> Enum.map(& &1.group_id)
        |> Components.direct_people(subject)

      resources =
        Enum.map(resources, fn resource ->
          resource_policies =
            policies
            |> Map.get(resource.id, [])
            |> Enum.map(&Map.put(&1, :label, policy_label(&1, people)))

          Map.put(resource, :policies, resource_policies)
        end)

      {:ok, %{resources: resources, resources_metadata: metadata}}
    end
  end

  defp policy_label(%{direct?: true, group_id: group_id}, people) do
    people |> Map.get(group_id, []) |> length() |> Components.people_count()
  end

  defp policy_label(policy, _people), do: policy.group_name

  defmodule Database do
    import Ecto.Query
    import Portal.Repo.Query
    alias Portal.{Safe, Group, Policy, Resource}

    def list_resources(subject, opts \\ []) do
      from(r in Resource, as: :resources)
      |> Safe.scoped(subject)
      |> Safe.list_offset(__MODULE__, opts)
    end

    def policies_by_resource([], _subject), do: %{}

    def policies_by_resource(resource_ids, subject) do
      from(p in Policy,
        join: g in Group,
        on: g.id == p.group_id and g.account_id == p.account_id,
        where: p.resource_id in ^resource_ids,
        order_by: [asc: not is_nil(g.resource_id), asc: g.name],
        select: %{
          id: p.id,
          resource_id: p.resource_id,
          group_id: g.id,
          group_name: g.name,
          direct?: not is_nil(g.resource_id),
          is_disabled: p.is_disabled
        }
      )
      |> Safe.scoped(subject)
      |> Safe.all()
      |> case do
        {:error, _reason} -> %{}
        rows -> Enum.group_by(rows, & &1.resource_id)
      end
    end

    def cursor_fields do
      [
        {:resources, :asc, :name},
        {:resources, :asc, :id}
      ]
    end

    def filters do
      [
        %Portal.Repo.Filter{
          name: :name_or_address,
          title: "Resource",
          type: {:string, :websearch},
          fun: &filter_by_name_or_address/2
        }
      ]
    end

    def filter_by_name_or_address(queryable, search_term) do
      {queryable,
       dynamic(
         [resources: r],
         fulltext_search(r.name, ^search_term) or fulltext_search(r.address, ^search_term)
       )}
    end
  end
end
