defmodule PortalWeb.Access.ByGroup do
  use PortalWeb, :live_view

  alias PortalWeb.Access.Components
  alias __MODULE__.Database

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Policies by group", groups: [], groups_metadata: %Portal.Repo.OffsetPaginator.Metadata{})
      |> LiveTable.assign_live_table("groups",
        query_module: Database,
        sortable_fields: [],
        loader: &load_groups/2
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
        <:title>Policies by group</:title>
        <:description>What each group can reach. Click a resource to open its policy.</:description>
        <:action>
          <Form.button style="primary" icon="ri-add-line" navigate={~p"/#{@account}/policies/new"}>
            Add a policy
          </Form.button>
        </:action>
      </Page.page_header>

      <div class="flex-1 flex flex-col min-h-0 overflow-hidden">
        <LiveTable.live_table
          id="groups"
          loading={@loading_by_table_id["groups"]}
          query_error={@query_error_by_table_id["groups"]}
          rows={@groups}
          row_id={&"groups-#{&1.id}"}
          filters={@filters_by_table_id["groups"]}
          filter={@filter_form_by_table_id["groups"]}
          ordered_by={@order_by_table_id["groups"]}
          metadata={@groups_metadata}
          class="flex-1 min-h-0"
        >
          <:col :let={group} label="Group" class="w-1/4">
            <.link
              navigate={~p"/#{@account}/groups/#{group.id}"}
              class="inline-flex items-center gap-2 font-medium text-fg hover:underline"
            >
              <Core.icon name="ri-group-line" class="w-4 h-4 text-muted shrink-0" />
              <span class="truncate">{group.name}</span>
            </.link>
          </:col>
          <:col :let={group} label="Can reach">
            <div class="flex flex-wrap gap-1.5">
              <Components.chip
                :for={policy <- group.policies}
                navigate={~p"/#{@account}/policies/#{policy.id}"}
                icon="ri-server-line"
                muted={policy.is_disabled}
                dashed={policy.resource_type == :device_pool}
                title={if policy.is_disabled, do: "Disabled policy", else: "Open the policy"}
              >
                {policy.resource_name}
                <span :if={policy.is_disabled} class="text-faint">(disabled)</span>
              </Components.chip>
              <span :if={group.policies == []} class="text-muted">Nothing</span>
            </div>
          </:col>
          <:col :let={group} label="Total" class="w-24 text-right">
            <span class="tabular-nums text-muted">{length(group.policies)}</span>
          </:col>
          <:empty>
            <div class="flex flex-col items-center gap-3 py-16">
              <Core.icon name="ri-group-line" class="w-6 h-6 text-faint" />
              <p class="text-sm text-muted">No groups yet.</p>
            </div>
          </:empty>
        </LiveTable.live_table>
      </div>
    </div>
    """
  end

  defp load_groups(subject, list_opts) do
    with {:ok, groups, metadata} <- Database.list_groups(subject, list_opts) do
      policies = Database.policies_by_group(Enum.map(groups, & &1.id), subject)
      groups = Enum.map(groups, &Map.put(&1, :policies, Map.get(policies, &1.id, [])))
      {:ok, %{groups: groups, groups_metadata: metadata}}
    end
  end

  defmodule Database do
    import Ecto.Query
    import Portal.Repo.Query
    alias Portal.{Safe, Group, Policy, Resource}

    def list_groups(subject, opts \\ []) do
      from(g in Group, as: :groups, where: is_nil(g.resource_id))
      |> Safe.scoped(subject)
      |> Safe.list_offset(__MODULE__, opts)
    end

    def policies_by_group([], _subject), do: %{}

    def policies_by_group(group_ids, subject) do
      from(p in Policy,
        join: r in Resource,
        on: r.id == p.resource_id and r.account_id == p.account_id,
        where: p.group_id in ^group_ids,
        order_by: [asc: r.name],
        select: %{
          id: p.id,
          group_id: p.group_id,
          is_disabled: p.is_disabled,
          resource_name: r.name,
          resource_type: r.type
        }
      )
      |> Safe.scoped(subject)
      |> Safe.all()
      |> case do
        {:error, _reason} -> %{}
        rows -> Enum.group_by(rows, & &1.group_id)
      end
    end

    def cursor_fields do
      [
        {:groups, :asc, :name},
        {:groups, :asc, :id}
      ]
    end

    def filters do
      [
        %Portal.Repo.Filter{
          name: :name,
          title: "Group",
          type: {:string, :websearch},
          fun: &filter_by_name/2
        }
      ]
    end

    def filter_by_name(queryable, search_term) do
      {queryable, dynamic([groups: g], fulltext_search(g.name, ^search_term))}
    end
  end
end
