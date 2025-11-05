defmodule Web.Groups do
  use Web, :live_view
  alias Domain.{Actors, Safe}
  alias __MODULE__.Query
  import Ecto.Changeset

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Groups")
      |> assign_live_table("groups",
        query_module: Query,
        sortable_fields: [
          {:groups, :name},
          {:groups, :updated_at}
        ],
        callback: &handle_groups_update!/2
      )

    {:ok, socket}
  end

  # Add Group Modal
  def handle_params(params, uri, %{assigns: %{live_action: :add}} = socket) do
    changeset = changeset(%{})
    socket = handle_live_tables_params(socket, params, uri)
    {:noreply, assign(socket, form: to_form(changeset))}
  end

  # Show Group Modal
  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :show}} = socket) do
    group = Query.get_group_with_actors!(id, socket.assigns.subject)
    socket = handle_live_tables_params(socket, params, uri)
    {:noreply, assign(socket, group: group)}
  end

  # Edit Group Modal
  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :edit}} = socket) do
    group = Query.get_group_with_actors!(id, socket.assigns.subject)
    changeset = changeset(group, %{})
    socket = handle_live_tables_params(socket, params, uri)

    {:noreply,
     assign(socket,
       group: group,
       form: to_form(changeset),
       members_to_add: group.actors,
       member_search_results: []
     )}
  end

  # Default handler
  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)
    {:noreply, socket}
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"],
    do: handle_live_table_event(event, params, socket)

  def handle_event("close_modal", _params, socket) do
    params = query_params(socket.assigns.uri)
    path = ~p"/#{socket.assigns.account}/groups?#{params}"
    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("validate", %{"group" => attrs}, socket) do
    member_search = Map.get(attrs, "member_search", "")

    search_results =
      if String.trim(member_search) != "" do
        Query.search_actors(member_search, socket.assigns.subject, socket.assigns.members_to_add)
      else
        []
      end

    changeset = changeset(socket.assigns.group, attrs)

    {:noreply,
     assign(socket,
       form: to_form(changeset),
       member_search_results: search_results
     )}
  end

  def handle_event("focus_search", _params, socket) do
    # Get the current search value from the form
    member_search = get_in(socket.assigns.form.params, ["member_search"]) || ""

    search_results =
      if String.trim(member_search) != "" do
        Query.search_actors(member_search, socket.assigns.subject, socket.assigns.members_to_add)
      else
        []
      end

    {:noreply, assign(socket, member_search_results: search_results)}
  end

  def handle_event("add_member", %{"actor_id" => actor_id}, socket) do
    actor = Query.get_actor!(actor_id, socket.assigns.subject)
    members_to_add = [actor | socket.assigns.members_to_add] |> Enum.uniq_by(& &1.id)

    {:noreply, assign(socket, members_to_add: members_to_add, member_search_results: [])}
  end

  def handle_event("remove_member", %{"actor_id" => actor_id}, socket) do
    members_to_add = Enum.reject(socket.assigns.members_to_add, &(&1.id == actor_id))

    {:noreply, assign(socket, members_to_add: members_to_add)}
  end

  def handle_groups_update!(socket, list_opts) do
    with {:ok, groups, metadata} <- Actors.list_groups(socket.assigns.subject, list_opts) do
      groups = Query.preload_member_count(groups)

      {:ok,
       assign(socket,
         groups: groups,
         groups_metadata: metadata
       )}
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/groups"}>{@page_title}</.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Groups
      </:title>

      <:action>
        <.docs_action path="/deploy/groups" />
      </:action>

      <:action>
        <.add_button navigate={~p"/#{@account}/groups/add?#{query_params(@uri)}"}>
          Add Group
        </.add_button>
      </:action>

      <:help>
        Groups organize Actors and form the basis of the Firezone access control model.
      </:help>

      <:content>
        <.flash_group flash={@flash} />
        <.live_table
          id="groups"
          rows={@groups}
          row_id={&"group-#{&1.id}"}
          row_patch={&row_patch_path(&1, @uri)}
          filters={@filters_by_table_id["groups"]}
          filter={@filter_form_by_table_id["groups"]}
          ordered_by={@order_by_table_id["groups"]}
          metadata={@groups_metadata}
        >
          <:col :let={group} field={{:groups, :name}} label="group" class="w-3/12">
            <.directory_icon directory={group.directory} />
            {group.name}
          </:col>
          <:col :let={group} label="members">
            {group.member_count}
          </:col>
          <:col :let={group} field={{:groups, :updated_at}} label="updated" class="w-2/12">
            <.relative_datetime datetime={group.updated_at} />
          </:col>
          <:empty>
            <div class="flex justify-center text-center text-neutral-500 p-4">
              <div class="w-auto pb-4">
                No groups to display.
                <.link class={[link_style()]} navigate={~p"/#{@account}/groups/add"}>
                  Add a group manually
                </.link>
                or
                <.link class={[link_style()]} navigate={~p"/#{@account}/settings/directory_sync"}>
                  go to settings
                </.link>
                to sync groups from an identity provider.
              </div>
            </div>
          </:empty>
        </.live_table>
      </:content>
    </.section>

    <!-- Add Group Modal -->
    <.modal
      :if={@live_action == :add}
      id="add-group-modal"
      on_close="close_modal"
      confirm_disabled={not @form.source.valid?}
    >
      <:title>Add Group</:title>
      <:body>
        <p>Add group form will go here</p>
      </:body>
      <:confirm_button form="group-form" type="submit">Create</:confirm_button>
    </.modal>

    <!-- Show Group Modal -->
    <.modal
      :if={@live_action == :show}
      id="show-group-modal"
      on_close="close_modal"
      max_width="lg"
    >
      <:title>
        <div class="flex items-center gap-3">
          <.directory_icon directory={@group.directory} class="w-6 h-6 flex-shrink-0" />
          <span class="text-xl font-semibold text-neutral-900 truncate">{@group.name}</span>
        </div>
      </:title>
      <:body>
        <div class="space-y-6">
          <div class="flex justify-end">
            <.button navigate={~p"/#{@account}/groups/edit/#{@group.id}?#{query_params(@uri)}"}>
              <.icon name="hero-pencil-square" class="w-4 h-4 mr-2" /> Edit
            </.button>
          </div>

          <div class="text-sm text-neutral-500 space-y-1">
            <div :if={@group.updated_at}>
              Last updated: <.relative_datetime datetime={@group.updated_at} />
            </div>
            <div :if={@group.last_synced_at}>
              Last synced: <.relative_datetime datetime={@group.last_synced_at} />
            </div>
          </div>

          <div>
            <h3 class="text-sm font-semibold text-neutral-900 mb-3">
              Members ({length(@group.actors)})
            </h3>

            <ul
              :if={@group.actors != []}
              class="border border-neutral-200 rounded-lg divide-y divide-neutral-200"
            >
              <li :for={actor <- @group.actors} class="p-3 hover:bg-neutral-50">
                <div class="flex items-center justify-between">
                  <div class="flex-1 min-w-0">
                    <p class="text-sm font-medium text-neutral-900 truncate">
                      {actor.name}
                    </p>
                    <p :if={actor.email} class="text-xs text-neutral-500 truncate">
                      {actor.email}
                    </p>
                  </div>
                  <div class="ml-4 flex-shrink-0">
                    <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-neutral-100 text-neutral-800">
                      {actor.type}
                    </span>
                  </div>
                </div>
              </li>
            </ul>

            <div
              :if={@group.actors == []}
              class="text-center py-8 border border-neutral-200 rounded-lg bg-neutral-50"
            >
              <p class="text-sm text-neutral-500">No members in this group.</p>
            </div>
          </div>
        </div>
      </:body>
    </.modal>

    <!-- Edit Group Modal -->
    <.modal
      :if={@live_action == :edit}
      id="edit-group-modal"
      on_close="close_modal"
      confirm_disabled={not @form.source.valid? or Enum.empty?(@form.source.changes)}
      max_width="lg"
    >
      <:title>Edit {@group.name}</:title>
      <:body>
        <.form id="group-form" for={@form} phx-change="validate" phx-submit="save">
          <div class="space-y-6">
            <.input field={@form[:name]} label="Group Name" placeholder="Enter group name" required />

            <div class="relative">
              <.input
                field={@form[:member_search]}
                label="Search Members"
                placeholder="Search by name or email..."
                phx-debounce="300"
                phx-focus="focus_search"
                autocomplete="off"
              />

              <div
                :if={@member_search_results && @member_search_results != []}
                class="absolute z-10 mt-1 w-full bg-white border border-neutral-300 rounded-lg shadow-lg max-h-60 overflow-y-auto"
              >
                <button
                  :for={actor <- @member_search_results}
                  type="button"
                  phx-click="add_member"
                  phx-value-actor_id={actor.id}
                  class="w-full text-left px-3 py-2 hover:bg-accent-50 border-b border-neutral-100 last:border-b-0"
                >
                  <div class="text-sm font-medium text-neutral-900">{actor.name}</div>
                  <div :if={actor.email} class="text-xs text-neutral-500">
                    {actor.email}
                  </div>
                </button>
              </div>
            </div>

            <div>
              <h3 class="text-sm font-semibold text-neutral-900 mb-3">
                Members ({length(@members_to_add)})
              </h3>

              <ul
                :if={@members_to_add != []}
                class="border border-neutral-200 rounded-lg divide-y divide-neutral-200 max-h-80 overflow-y-auto"
              >
                <li
                  :for={actor <- @members_to_add}
                  class="p-3 flex items-center justify-between group"
                >
                  <div class="flex-1 min-w-0">
                    <p class="text-sm font-medium text-neutral-900 truncate">
                      {actor.name}
                    </p>
                    <p :if={actor.email} class="text-xs text-neutral-500 truncate">
                      {actor.email}
                    </p>
                  </div>
                  <div class="ml-4 flex items-center gap-2">
                    <span
                      :if={Enum.any?(@group.actors, &(&1.id == actor.id))}
                      class="text-xs text-neutral-500"
                    >
                      Current
                    </span>
                    <span
                      :if={not Enum.any?(@group.actors, &(&1.id == actor.id))}
                      class="text-xs text-green-600 font-medium"
                    >
                      To Add
                    </span>
                    <button
                      type="button"
                      phx-click="remove_member"
                      phx-value-actor_id={actor.id}
                      class="flex-shrink-0 text-neutral-400 hover:text-red-600 opacity-0 group-hover:opacity-100 transition-opacity"
                    >
                      <.icon name="hero-user-minus" class="w-5 h-5" />
                    </button>
                  </div>
                </li>
              </ul>

              <div
                :if={@members_to_add == []}
                class="text-center py-8 border border-neutral-200 rounded-lg bg-neutral-50"
              >
                <p class="text-sm text-neutral-500">No members in this group.</p>
              </div>
            </div>
          </div>
        </.form>
      </:body>
      <:confirm_button form="group-form" type="submit">Save</:confirm_button>
    </.modal>
    """
  end

  attr :directory, :map, default: %{}
  attr :class, :string, default: "inline w-4 h-4 mr-1"

  defp directory_icon(%{directory: %{"directory" => "g:" <> _directory}} = assigns) do
    ~H"""
    <.provider_icon type="google" class={@class} />
    """
  end

  defp directory_icon(%{directory: %{"directory" => "e:" <> _directory}} = assigns) do
    ~H"""
    <.provider_icon type="entra" class={@class} />
    """
  end

  defp directory_icon(%{directory: %{"directory" => "o:" <> _directory}} = assigns) do
    ~H"""
    <.provider_icon type="okta" class={@class} />
    """
  end

  defp directory_icon(assigns) do
    ~H"""
    <.provider_icon type="firezone" class={@class} />
    """
  end

  defp query_params(uri) do
    uri = URI.parse(uri)
    if uri.query, do: URI.decode_query(uri.query), else: %{}
  end

  defp row_patch_path(group, uri) do
    params = query_params(uri)
    ~p"/#{group.account_id}/groups/show/#{group.id}?#{params}"
  end

  defp changeset(group \\ %Actors.Group{}, attrs) do
    cast(group, attrs, [:name])
    |> Actors.Group.changeset()
  end

  defp create_group(changeset, subject) do
    Safe.scoped(subject)
    |> Safe.insert(changeset)
  end

  defp update_group(changeset, subject) do
    Safe.scoped(subject)
    |> Safe.update(changeset)
  end

  defmodule Query do
    import Ecto.Query

    def get_group!(id, subject) do
      query =
        from(g in Actors.Group, as: :groups)
        |> where([groups: groups], groups.id == ^id)

      Safe.scoped(subject) |> Safe.one!(query)
    end

    def get_actor!(id, subject) do
      query =
        from(a in Actors.Actor, as: :actors)
        |> where([actors: a], a.id == ^id)

      Safe.scoped(subject) |> Safe.one!(query)
    end

    def search_actors(search_term, subject, exclude_actors) do
      exclude_ids = Enum.map(exclude_actors, & &1.id)
      search_pattern = "%#{search_term}%"

      query =
        from(a in Actors.Actor, as: :actors)
        |> where(
          [actors: a],
          (ilike(a.name, ^search_pattern) or ilike(a.email, ^search_pattern)) and
            a.id not in ^exclude_ids
        )
        |> limit(10)

      case Safe.scoped(subject) |> Safe.all(query) do
        actors when is_list(actors) -> actors
        {:error, _} -> []
      end
    end

    def get_group_with_actors!(id, subject) do
      query =
        from(g in Actors.Group, as: :groups)
        |> where([groups: groups], groups.id == ^id)
        |> join(:left, [groups: g], m in assoc(g, :memberships), as: :memberships)
        |> join(:left, [memberships: m], a in assoc(m, :actor), as: :actors)
        |> preload([actors: a], actors: a)

      Safe.scoped(subject) |> Safe.one!(query)
    end

    def preloads do
      [
        member_count: &preload_member_count/1
      ]
    end

    def preload_member_count(groups) do
      group_ids = Enum.map(groups, & &1.id)

      counts =
        from(m in Actors.Membership,
          where: m.group_id in ^group_ids,
          group_by: m.group_id,
          select: {m.group_id, count(m.actor_id)}
        )
        |> Domain.Repo.all()
        |> Map.new()

      Enum.map(groups, fn group ->
        %{group | member_count: Map.get(counts, group.id, 0)}
      end)
    end
  end
end
