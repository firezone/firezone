defmodule Web.Groups do
  use Web, :live_view

  alias __MODULE__.DB

  import Ecto.Changeset

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Groups")
      |> assign_live_table("groups",
        query_module: DB,
        sortable_fields: [
          {:groups, :name},
          {:member_counts, :count},
          {:groups, :updated_at}
        ],
        callback: &handle_groups_update!/2
      )

    {:ok, socket}
  end

  # Add Group Modal
  def handle_params(params, uri, %{assigns: %{live_action: :add}} = socket) do
    changeset = changeset(%Domain.Group{}, %{})
    socket = handle_live_tables_params(socket, params, uri)

    {:noreply,
     assign(socket,
       form: to_form(changeset),
       members_to_add: [],
       member_search_results: nil,
       last_member_search: ""
     )}
  end

  # Show Group Modal
  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :show}} = socket) do
    group = DB.get_group_with_actors!(id, socket.assigns.subject)
    socket = handle_live_tables_params(socket, params, uri)

    {:noreply, assign(socket, group: group, show_member_filter: "")}
  end

  # Edit Group Modal
  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :edit}} = socket) do
    group = DB.get_group_with_actors!(id, socket.assigns.subject)
    socket = handle_live_tables_params(socket, params, uri)

    if editable_group?(group) do
      changeset = changeset(group, %{})

      {:noreply,
       assign(socket,
         group: group,
         form: to_form(changeset),
         members_to_add: [],
         members_to_remove: [],
         member_search_results: nil,
         last_member_search: ""
       )}
    else
      # Redirect to show if trying to edit a protected group
      {:noreply,
       socket
       |> put_flash(:error, "This group cannot be edited")
       |> push_patch(
         to: ~p"/#{socket.assigns.account}/groups/#{id}?#{socket.assigns.query_params}"
       )}
    end
  end

  # Default handler
  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)
    {:noreply, socket}
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"],
    do: handle_live_table_event(event, params, socket)

  def handle_event("close_modal", _params, socket) do
    {:noreply, close_modal(socket)}
  end

  def handle_event("validate", %{"group" => attrs}, socket) do
    group = Map.get(socket.assigns, :group, %Domain.Group{})
    changeset = changeset(group, attrs)

    # Only search if member_search value has changed
    current_search = Map.get(attrs, "member_search", "")
    last_search = socket.assigns.last_member_search

    {member_search_results, last_member_search} =
      if current_search != last_search do
        {get_search_results(current_search, socket), current_search}
      else
        {socket.assigns.member_search_results, last_search}
      end

    {:noreply,
     assign(socket,
       form: to_form(changeset),
       member_search_results: member_search_results,
       last_member_search: last_member_search
     )}
  end

  def handle_event("focus_search", _params, socket) do
    member_search = get_in(socket.assigns.form.params, ["member_search"]) || ""
    search_results = get_search_results(member_search, socket)
    {:noreply, assign(socket, member_search_results: search_results)}
  end

  def handle_event("add_member", %{"actor_id" => actor_id}, socket) do
    actor = DB.get_actor!(actor_id, socket.assigns.subject)

    {members_to_add, members_to_remove} =
      if Map.has_key?(socket.assigns, :members_to_remove) do
        add_member(actor, socket)
      else
        {uniq_by_id([actor | socket.assigns.members_to_add]), []}
      end

    group = Map.get(socket.assigns, :group, %Domain.Group{})
    updated_params = Map.put(socket.assigns.form.params, "member_search", "")
    changeset = changeset(group, updated_params)

    assigns = [
      members_to_add: members_to_add,
      member_search_results: nil,
      form: to_form(changeset),
      last_member_search: ""
    ]

    assigns =
      if members_to_remove != [],
        do: Keyword.put(assigns, :members_to_remove, members_to_remove),
        else: assigns

    {:noreply, assign(socket, assigns)}
  end

  def handle_event("remove_member", %{"actor_id" => actor_id}, socket) do
    {members_to_add, members_to_remove} = remove_member(actor_id, socket)

    {:noreply,
     assign(socket, members_to_add: members_to_add, members_to_remove: members_to_remove)}
  end

  def handle_event("blur_search", _params, socket) do
    {:noreply, assign(socket, member_search_results: nil)}
  end

  def handle_event("filter_show_members", %{"filter" => filter}, socket) do
    {:noreply, assign(socket, show_member_filter: filter)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    group = DB.get_group!(id, socket.assigns.subject)

    if deletable_group?(group) do
      case DB.delete(group, socket.assigns.subject) do
        {:ok, _group} ->
          {:noreply, handle_success(socket, "Group deleted successfully")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to delete group")}
      end
    else
      {:noreply, put_flash(socket, :error, "This group cannot be deleted")}
    end
  end

  def handle_event("create", %{"group" => attrs}, socket) do
    attrs = build_attrs_with_memberships_for_add(attrs, socket)
    group = %Domain.Group{account_id: socket.assigns.subject.account.id}
    changeset = changeset(group, attrs)

    case DB.create(changeset, socket.assigns.subject) do
      {:ok, _group} ->
        socket =
          socket
          |> put_flash(:success, "Group created successfully")
          |> reload_live_table!("groups")
          |> push_patch(to: ~p"/#{socket.assigns.account}/groups")

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("save", %{"group" => attrs}, socket) do
    if editable_group?(socket.assigns.group) do
      attrs = build_attrs_with_memberships(attrs, socket)
      changeset = changeset(socket.assigns.group, attrs)

      case DB.update(changeset, socket.assigns.subject) do
        {:ok, group} ->
          socket =
            socket
            |> put_flash(:success_inline, "Group updated successfully")
            |> reload_live_table!("groups")
            |> push_patch(
              to: ~p"/#{socket.assigns.account}/groups/#{group.id}?#{socket.assigns.query_params}"
            )

          {:noreply, socket}

        {:error, changeset} ->
          {:noreply, assign(socket, form: to_form(changeset))}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "This group cannot be edited")
       |> close_modal()}
    end
  end

  def handle_groups_update!(socket, list_opts) do
    with {:ok, groups, metadata} <- DB.list_groups(socket.assigns.subject, list_opts) do
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
        <.add_button navigate={~p"/#{@account}/groups/add?#{@query_params}"}>
          Add Group
        </.add_button>
      </:action>

      <:help>
        Groups organize Actors and form the basis of the Firezone access control model.
      </:help>

      <:content>
        <.live_table
          id="groups"
          rows={@groups}
          row_id={&"group-#{&1.id}"}
          row_patch={&row_patch_path(&1, @query_params)}
          filters={@filters_by_table_id["groups"]}
          filter={@filter_form_by_table_id["groups"]}
          ordered_by={@order_by_table_id["groups"]}
          metadata={@groups_metadata}
        >
          <:col :let={group} class="w-12">
            <.provider_icon type={provider_type_from_group(group)} class="w-8 h-8" />
          </:col>
          <:col :let={group} field={{:groups, :name}} label="group" class="w-3/12">
            <span class="flex items-center gap-2">
              {group.name}
              <span
                :if={group.entity_type == :org_unit}
                class="inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium bg-neutral-100 text-neutral-600"
                title="Organizational Unit"
              >
                OU
              </span>
            </span>
          </:col>
          <:col :let={group} field={{:member_counts, :count}} label="members">
            {group.member_count}
          </:col>
          <:col :let={group} field={{:groups, :updated_at}} label="updated">
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
        <.form id="group-form" for={@form} phx-change="validate" phx-submit="create">
          <div class="space-y-6">
            <.input
              field={@form[:name]}
              label="Group Name"
              placeholder="Enter group name"
              autocomplete="off"
              phx-debounce="300"
              data-1p-ignore
              required
            />

            <div>
              <h3 class="text-sm font-semibold text-neutral-900 mb-3">
                Members ({length(@members_to_add)})
              </h3>

              <div class="border border-neutral-200 rounded-lg overflow-hidden">
                <.member_search_input form={@form} member_search_results={@member_search_results} />

                <.member_list members={@members_to_add}>
                  <:badge :let={actor}>
                    <.actor_type_badge actor={actor} />
                  </:badge>
                  <:actions :let={actor}>
                    <div class="ml-4 flex items-center gap-2">
                      <button
                        type="button"
                        phx-click="remove_member"
                        phx-value-actor_id={actor.id}
                        class="flex-shrink-0 text-neutral-400 hover:text-red-600 group-hover:font-bold transition-all"
                      >
                        <.icon name="hero-user-minus" class="w-5 h-5" />
                      </button>
                    </div>
                  </:actions>
                  <:empty_message>
                    No members in this group.
                  </:empty_message>
                </.member_list>
              </div>
            </div>
          </div>
        </.form>
      </:body>
      <:confirm_button form="group-form" type="submit">Create</:confirm_button>
    </.modal>

    <!-- Show Group Modal -->
    <.modal
      :if={@live_action == :show}
      id="show-group-modal"
      on_close="close_modal"
    >
      <:title>
        <div class="flex items-center gap-3">
          <.provider_icon
            type={provider_type_from_group(@group)}
            class="w-8 h-8 flex-shrink-0"
          />
          <span>{@group.name}</span>
        </div>
      </:title>
      <:body>
        <.flash id="group-success-inline-show" kind={:success_inline} style="inline" flash={@flash} />
        <div class="space-y-6">
          <div>
            <div class="flex items-center justify-between mb-3">
              <h3 class="text-sm font-semibold text-neutral-900">Details</h3>
              <.popover :if={deletable_group?(@group)} placement="bottom-end" trigger="click">
                <:target>
                  <button
                    type="button"
                    class="text-neutral-500 hover:text-neutral-700 focus:outline-none"
                  >
                    <.icon name="hero-ellipsis-horizontal" class="w-6 h-6" />
                  </button>
                </:target>
                <:content>
                  <div class="py-1">
                    <.link
                      :if={editable_group?(@group)}
                      navigate={~p"/#{@account}/groups/#{@group.id}/edit?#{@query_params}"}
                      class="px-3 py-2 text-sm text-neutral-800 rounded-lg hover:bg-neutral-100 flex items-center gap-2 whitespace-nowrap"
                    >
                      <.icon name="hero-pencil" class="w-4 h-4" /> Edit
                    </.link>
                    <div
                      :if={not editable_group?(@group)}
                      class="px-3 py-2 text-sm text-neutral-400 rounded-lg flex items-center gap-2 whitespace-nowrap cursor-not-allowed"
                      title="Synced groups cannot be edited"
                    >
                      <.icon name="hero-pencil" class="w-4 h-4" /> Edit
                    </div>
                    <button
                      type="button"
                      phx-click="delete"
                      phx-value-id={@group.id}
                      class="w-full px-3 py-2 text-sm text-red-600 rounded-lg hover:bg-neutral-100 flex items-center gap-2 border-0 bg-transparent whitespace-nowrap"
                      data-confirm="Are you sure you want to delete this group?"
                    >
                      <.icon name="hero-trash" class="w-4 h-4" /> Delete
                    </button>
                  </div>
                </:content>
              </.popover>
            </div>

            <div class="grid grid-cols-2 gap-4">
              <div>
                <p class="text-xs font-medium text-neutral-500 uppercase">ID</p>
                <p class="text-sm text-neutral-900 font-mono truncate" title={@group.id}>
                  {@group.id}
                </p>
              </div>
              <div :if={@group.entity_type == :org_unit}>
                <p class="text-xs font-medium text-neutral-500 uppercase">Type</p>
                <p class="text-sm text-neutral-900">
                  Org Unit
                </p>
              </div>
              <div>
                <p class="text-xs font-medium text-neutral-500 uppercase">Created</p>
                <p class="text-sm text-neutral-900">
                  <.relative_datetime datetime={@group.inserted_at} />
                </p>
              </div>
              <div>
                <p class="text-xs font-medium text-neutral-500 uppercase">Directory</p>
                <p class="text-sm text-neutral-900 truncate" title={directory_display_name(@group)}>
                  {directory_display_name(@group)}
                </p>
              </div>
              <div>
                <p class="text-xs font-medium text-neutral-500 uppercase">Updated</p>
                <p class="text-sm text-neutral-900">
                  <.relative_datetime datetime={@group.updated_at} />
                </p>
              </div>
              <div :if={@group.last_synced_at}>
                <p class="text-xs font-medium text-neutral-500 uppercase">Last Synced</p>
                <p class="text-sm text-neutral-900">
                  <.relative_datetime datetime={@group.last_synced_at} />
                </p>
              </div>
              <div :if={@group.idp_id && get_idp_id(@group.idp_id)}>
                <p class="text-xs font-medium text-neutral-500 uppercase">Identity Provider ID</p>
                <p
                  class="text-sm text-neutral-900 font-mono truncate"
                  title={get_idp_id(@group.idp_id)}
                >
                  {get_idp_id(@group.idp_id)}
                </p>
              </div>
            </div>
          </div>

          <div>
            <h3 class="text-sm font-semibold text-neutral-900 mb-3">
              Members ({length(@group.actors)})
            </h3>

            <% filtered_actors = filter_members(@group.actors, @show_member_filter) %>

            <div class="border border-neutral-200 rounded-lg overflow-hidden">
              <.member_filter_input show_member_filter={@show_member_filter} />

              <.member_list members={filtered_actors} item_class="p-3 hover:bg-neutral-50 group">
                <:badge :let={actor}>
                  <.actor_type_badge actor={actor} />
                </:badge>
                <:empty_message>
                  <%= if has_content?(@show_member_filter) do %>
                    No members match your filter.
                  <% else %>
                    No members in this group.
                  <% end %>
                </:empty_message>
              </.member_list>
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
      on_back={JS.patch(~p"/#{@account}/groups/#{@group}?#{@query_params}")}
      confirm_disabled={edit_form_unchanged?(@form, @members_to_add, @members_to_remove)}
    >
      <:title>
        <div class="flex items-center gap-3">
          <.provider_icon
            type={provider_type_from_group(@group)}
            class="w-8 h-8 flex-shrink-0"
          />
          <span>Edit {@group.name}</span>
        </div>
      </:title>
      <:body>
        <.flash id="group-success-inline" kind={:success_inline} style="inline" flash={@flash} />
        <.form id="group-form" for={@form} phx-change="validate" phx-submit="save">
          <div class="space-y-6">
            <.input
              field={@form[:name]}
              label="Group Name"
              placeholder="Enter group name"
              autocomplete="off"
              phx-debounce="300"
              data-1p-ignore
              required
            />

            <div>
              <% all_members =
                get_all_members_for_display(@group, @members_to_add, @members_to_remove) %>
              <h3 class="text-sm font-semibold text-neutral-900 mb-3">
                Members ({get_member_count(all_members, @members_to_remove)})
              </h3>

              <div class="border border-neutral-200 rounded-lg overflow-hidden">
                <.member_search_input form={@form} member_search_results={@member_search_results} />

                <.member_list members={all_members}>
                  <:badge :let={actor}>
                    <.actor_type_badge actor={actor} />
                  </:badge>
                  <:actions :let={actor}>
                    <div class="ml-4 flex items-center gap-2">
                      <% is_current = current_member?(actor, @group)
                      is_to_add = Enum.any?(@members_to_add, &(&1.id == actor.id))
                      is_to_remove = Enum.any?(@members_to_remove, &(&1.id == actor.id)) %>
                      <span :if={is_current and not is_to_remove} class="text-xs text-neutral-500">
                        Current
                      </span>
                      <span :if={is_to_add} class="text-xs text-green-600 font-medium">
                        To Add
                      </span>
                      <span :if={is_to_remove} class="text-xs text-red-600 font-medium">
                        To Remove
                      </span>
                      <button
                        type="button"
                        phx-click="remove_member"
                        phx-value-actor_id={actor.id}
                        class="flex-shrink-0 text-neutral-400 hover:text-red-600 group-hover:font-bold transition-all"
                      >
                        <.icon name="hero-user-minus" class="w-5 h-5" />
                      </button>
                    </div>
                  </:actions>
                  <:empty_message>
                    No members in this group.
                  </:empty_message>
                </.member_list>
              </div>
            </div>
          </div>
        </.form>
      </:body>
      <:back_button>Back</:back_button>
      <:confirm_button form="group-form" type="submit">Save</:confirm_button>
    </.modal>
    """
  end

  defp actor_type_badge(assigns) do
    assigns = assign_new(assigns, :class, fn -> "w-7 h-7" end)

    ~H"""
    <div class={[
      "inline-flex items-center justify-center rounded-full flex-shrink-0",
      @class,
      actor_type_icon_bg_color(@actor.type)
    ]}>
      <%= case @actor.type do %>
        <% :service_account -> %>
          <.icon name="hero-server" class={"w-4 h-4 #{actor_type_icon_text_color(@actor.type)}"} />
        <% :account_admin_user -> %>
          <.icon
            name="hero-shield-check"
            class={"w-4 h-4 #{actor_type_icon_text_color(@actor.type)}"}
          />
        <% _ -> %>
          <.icon name="hero-user" class={"w-4 h-4 #{actor_type_icon_text_color(@actor.type)}"} />
      <% end %>
    </div>
    """
  end

  defp actor_type_icon_bg_color(:service_account), do: "bg-blue-100"
  defp actor_type_icon_bg_color(:account_admin_user), do: "bg-purple-100"
  defp actor_type_icon_bg_color(_), do: "bg-neutral-100"

  defp actor_type_icon_text_color(:service_account), do: "text-blue-800"
  defp actor_type_icon_text_color(:account_admin_user), do: "text-purple-800"
  defp actor_type_icon_text_color(_), do: "text-neutral-800"

  defp member_search_input(assigns) do
    assigns = assign_new(assigns, :placeholder, fn -> "Search to add members..." end)

    ~H"""
    <div class="p-3 bg-neutral-50 border-b border-neutral-200 relative" phx-click-away="blur_search">
      <input
        type="text"
        name={@form[:member_search].name}
        value={@form[:member_search].value}
        placeholder={@placeholder}
        phx-debounce="300"
        phx-focus="focus_search"
        autocomplete="off"
        data-1p-ignore
        class="block w-full rounded-lg border-neutral-300 focus:border-accent-400 focus:ring focus:ring-accent-200 focus:ring-opacity-50 text-neutral-900 text-sm"
      />

      <div
        :if={@member_search_results != nil}
        class="absolute z-10 left-3 right-3 mt-1 bg-white border border-neutral-300 rounded-lg shadow-lg max-h-48 overflow-y-auto"
      >
        <button
          :for={actor <- @member_search_results}
          type="button"
          phx-click="add_member"
          phx-value-actor_id={actor.id}
          class="w-full text-left px-3 py-2 hover:bg-accent-50 border-b border-neutral-100 last:border-b-0"
        >
          <div class="space-y-0.5">
            <div class="flex items-start gap-2">
              <.actor_type_badge actor={actor} />
              <div class="text-sm font-medium text-neutral-900">{actor.name}</div>
            </div>
            <div :if={actor.email} class="text-xs text-neutral-500">
              {actor.email}
            </div>
          </div>
        </button>
        <div
          :if={@member_search_results == []}
          class="px-3 py-4 text-center text-sm text-neutral-500"
        >
          No members found
        </div>
      </div>
    </div>
    """
  end

  defp member_filter_input(assigns) do
    ~H"""
    <form phx-change="filter_show_members" class="p-3 bg-neutral-50 border-b border-neutral-200">
      <input
        type="text"
        value={@show_member_filter}
        placeholder="Filter members..."
        phx-debounce="300"
        name="filter"
        autocomplete="off"
        data-1p-ignore
        class="block w-full rounded-lg border-neutral-300 focus:border-accent-400 focus:ring focus:ring-accent-200 focus:ring-opacity-50 text-neutral-900 text-sm"
      />
    </form>
    """
  end

  defp member_list(assigns) do
    assigns =
      assigns
      |> assign_new(:item_class, fn -> "p-3 flex items-center justify-between group" end)
      |> assign(:has_actions, Map.get(assigns, :actions) != nil)

    ~H"""
    <ul :if={@members != []} class="divide-y divide-neutral-200 h-64 overflow-y-auto">
      <li :for={actor <- @members} class={@item_class}>
        <div class={["flex items-center gap-3", @has_actions && "flex-1 min-w-0"]}>
          <%= if Map.get(assigns, :badge) do %>
            {render_slot(@badge, actor)}
          <% end %>
          <div class={@has_actions && "flex-1 min-w-0"}>
            <p class={["text-sm font-medium text-neutral-900", @has_actions && "truncate"]}>
              {actor.name}
            </p>
            <p :if={actor.email} class={["text-xs text-neutral-500", @has_actions && "truncate"]}>
              {actor.email}
            </p>
          </div>
        </div>
        <%= if @has_actions do %>
          {render_slot(@actions, actor)}
        <% end %>
      </li>
    </ul>

    <div :if={@members == []} class="flex items-center justify-center h-64 bg-white">
      <p class="text-sm text-neutral-500">
        {render_slot(@empty_message)}
      </p>
    </div>
    """
  end

  defp editable_group?(%{type: :managed, name: "Everyone"}), do: false
  defp editable_group?(%{idp_id: nil}), do: true
  defp editable_group?(_group), do: false

  defp deletable_group?(%{name: "Everyone"}), do: false
  defp deletable_group?(_group), do: true

  defp directory_display_name(%{directory_name: name}) when not is_nil(name), do: name
  defp directory_display_name(%{idp_id: idp_id}) when not is_nil(idp_id), do: "Unknown"
  defp directory_display_name(_), do: "Firezone"

  defp get_idp_id(nil), do: nil

  defp get_idp_id(idp_id) do
    case String.split(idp_id, ":", parts: 2) do
      [_provider, actual_id] -> actual_id
      _ -> idp_id
    end
  end

  defp filter_members(actors, filter) do
    if has_content?(filter) do
      search_pattern = String.downcase(filter)

      Enum.filter(actors, fn actor ->
        String.contains?(String.downcase(actor.name || ""), search_pattern) or
          String.contains?(String.downcase(actor.email || ""), search_pattern)
      end)
    else
      actors
    end
  end

  # Utility helpers
  defp has_content?(str), do: String.trim(str) != ""

  defp uniq_by_id(list), do: Enum.uniq_by(list, & &1.id)

  defp handle_success(socket, message) do
    socket
    |> put_flash(:success, message)
    |> reload_live_table!("groups")
    |> close_modal()
  end

  defp edit_form_unchanged?(form, members_to_add, members_to_remove) do
    not form.source.valid? or
      (Enum.empty?(form.source.changes) and members_to_add == [] and members_to_remove == [])
  end

  # Navigation helpers
  defp row_patch_path(group, query_params) do
    ~p"/#{group.account_id}/groups/#{group.id}?#{query_params}"
  end

  defp close_modal(socket) do
    if return_to = handle_return_to(socket) do
      push_navigate(socket, to: return_to)
    else
      push_patch(socket, to: ~p"/#{socket.assigns.account}/groups?#{socket.assigns.query_params}")
    end
  end

  defp handle_return_to(%{
         assigns: %{query_params: %{"return_to" => return_to}, current_path: current_path}
       })
       when not is_nil(return_to) and not is_nil(current_path) do
    validate_return_to(
      String.split(return_to, "/", parts: 2),
      String.split(current_path, "/", parts: 2)
    )
  end

  defp handle_return_to(_socket), do: nil

  defp validate_return_to([account | _ret_parts] = return_to, [account | _cur_parts]),
    do: Enum.join(return_to, "/")

  defp validate_return_to(_return_to, _current_path), do: nil

  # Member search helpers
  defp get_search_results(search_term, socket) do
    if has_content?(search_term) do
      DB.search_actors(search_term, socket.assigns.subject, socket.assigns.members_to_add)
    else
      nil
    end
  end

  # Member management helpers
  defp get_all_members_for_display(group, members_to_add, members_to_remove) do
    # Combine current members and members to add, remove duplicates
    all_members = uniq_by_id(group.actors ++ members_to_add)

    # Remove members marked for deletion, then add them back at the end (to show "To Remove")
    all_members
    |> Enum.reject(fn actor -> Enum.any?(members_to_remove, &(&1.id == actor.id)) end)
    |> Kernel.++(members_to_remove)
  end

  defp get_member_count(all_members, members_to_remove) do
    length(all_members) - length(members_to_remove)
  end

  defp add_member(actor, socket) do
    members_to_remove = Enum.reject(socket.assigns.members_to_remove, &(&1.id == actor.id))

    members_to_add =
      if current_member?(actor, socket.assigns.group) do
        socket.assigns.members_to_add
      else
        uniq_by_id([actor | socket.assigns.members_to_add])
      end

    {members_to_add, members_to_remove}
  end

  defp remove_member(actor_id, socket) do
    members_to_add = Enum.reject(socket.assigns.members_to_add, &(&1.id == actor_id))

    members_to_remove =
      if actor = find_current_member(actor_id, socket.assigns.group) do
        uniq_by_id([actor | socket.assigns.members_to_remove])
      else
        socket.assigns.members_to_remove
      end

    {members_to_add, members_to_remove}
  end

  defp current_member?(actor, group) do
    Enum.any?(group.actors, &(&1.id == actor.id))
  end

  defp find_current_member(actor_id, group) do
    Enum.find(group.actors, &(&1.id == actor_id))
  end

  defp build_attrs_with_memberships(attrs, socket) do
    final_member_ids = calculate_final_member_ids(socket)
    memberships = Enum.map(final_member_ids, &%{actor_id: &1})
    Map.put(attrs, "memberships", memberships)
  end

  defp build_attrs_with_memberships_for_add(attrs, socket) do
    member_ids = Enum.map(socket.assigns.members_to_add, & &1.id)
    memberships = Enum.map(member_ids, &%{actor_id: &1})
    Map.put(attrs, "memberships", memberships)
  end

  defp calculate_final_member_ids(socket) do
    current_ids = Enum.map(socket.assigns.group.actors, & &1.id)
    to_add_ids = Enum.map(socket.assigns.members_to_add, & &1.id)
    to_remove_ids = Enum.map(socket.assigns.members_to_remove, & &1.id)

    (current_ids ++ to_add_ids)
    |> Enum.uniq()
    |> Enum.reject(&(&1 in to_remove_ids))
  end

  # Changesets
  defp changeset(group, attrs) do
    group
    |> cast(attrs, [:name])
    |> cast_assoc(:memberships,
      with: fn membership, attrs ->
        membership
        |> cast(attrs, [:actor_id])
        |> validate_required([:actor_id])
        |> put_change(:account_id, group.account_id)
      end
    )
  end

  defmodule DB do
    import Ecto.Query
    alias Domain.Safe
    alias Domain.Directory
    alias Domain.Repo.Filter

    def all do
      from(groups in Domain.Group, as: :groups)
    end

    # Inlined from Domain.Actors.list_groups
    def list_groups(subject, opts \\ []) do
      # Extract order_by to handle member_count sorting specially
      {order_by, opts} = Keyword.pop(opts, :order_by, [])

      member_counts_query =
        from(m in Domain.Membership,
          group_by: m.group_id,
          select: %{
            group_id: m.group_id,
            count: count(m.actor_id)
          }
        )

      query =
        from(g in Domain.Group, as: :groups)
        |> join(:left, [groups: g], mc in subquery(member_counts_query),
          on: mc.group_id == g.id,
          as: :member_counts
        )
        |> join(:left, [groups: g], d in Directory,
          on: d.id == g.directory_id,
          as: :directory
        )
        |> where(
          [groups: g],
          not (g.type == :managed and is_nil(g.idp_id) and g.name == "Everyone")
        )
        |> select_merge([groups: g, member_counts: mc, directory: d], %{
          count: coalesce(mc.count, 0),
          member_count: coalesce(mc.count, 0),
          directory_type: d.type
        })

      # Apply manual ordering with NULLS LAST for count field
      {query, final_order_by} =
        case order_by do
          [{:member_counts, :desc, :count}] ->
            # Apply ordering manually with NULLS LAST, don't pass to Safe.list
            updated_query =
              query
              |> order_by([member_counts: mc], fragment("? DESC NULLS LAST", mc.count))

            {updated_query, []}

          [{:member_counts, :asc, :count}] ->
            # Apply ordering manually with NULLS FIRST, don't pass to Safe.list
            updated_query =
              query
              |> order_by([member_counts: mc], fragment("? ASC NULLS FIRST", mc.count))

            {updated_query, []}

          _ ->
            # Let Safe.list handle the ordering normally
            {query, order_by}
        end

      query
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, Keyword.put(opts, :order_by, final_order_by))
    end

    def cursor_fields do
      [
        {:groups, :asc, :inserted_at},
        {:groups, :asc, :id}
      ]
    end

    def filters do
      [
        %Filter{
          name: :directory_id,
          title: "Directory",
          type: {:string, :select},
          values: &directory_values/1,
          fun: &filter_by_directory/2
        },
        %Filter{
          name: :name,
          title: "Name",
          type: {:string, :websearch},
          fun: &filter_by_name/2
        }
      ]
    end

    # Define a simple struct-like module for directory options
    defmodule DirectoryOption do
      defstruct [:id, :name]
    end

    defp directory_values(subject) do
      directories =
        from(d in Directory,
          where: d.account_id == ^subject.account.id,
          left_join: google in Domain.Google.Directory,
          on: google.id == d.id and d.type == :google,
          left_join: entra in Domain.Entra.Directory,
          on: entra.id == d.id and d.type == :entra,
          left_join: okta in Domain.Okta.Directory,
          on: okta.id == d.id and d.type == :okta,
          select: %{
            id: d.id,
            name: fragment("COALESCE(?, ?, ?)", google.name, entra.name, okta.name),
            type: d.type
          },
          order_by: [asc: fragment("COALESCE(?, ?, ?)", google.name, entra.name, okta.name)]
        )
        |> Safe.scoped(subject)
        |> Safe.all()
        |> case do
          {:error, _} ->
            []

          directories ->
            directories
            |> Enum.map(fn %{id: id, name: name} ->
              %DirectoryOption{id: id, name: name}
            end)
        end

      # Add Firezone option at the beginning
      [%DirectoryOption{id: "firezone", name: "Firezone"} | directories]
    end

    def filter_by_directory(queryable, "firezone") do
      # Firezone directory - groups created without a directory
      {queryable, dynamic([groups: groups], is_nil(groups.directory_id))}
    end

    def filter_by_directory(queryable, directory_id) do
      # Filter for groups created by a specific directory
      {queryable, dynamic([groups: groups], groups.directory_id == ^directory_id)}
    end

    def filter_by_name(queryable, search_term) do
      search_pattern = "%#{search_term}%"

      {queryable, dynamic([groups: groups], ilike(groups.name, ^search_pattern))}
    end

    def get_group!(id, subject) do
      from(g in Domain.Group, as: :groups)
      |> join(:left, [groups: g], d in Directory,
        on: d.id == g.directory_id,
        as: :directory
      )
      |> where([groups: groups], groups.id == ^id)
      |> select_merge([groups: g, directory: d], %{
        directory_type: d.type
      })
      |> Safe.scoped(subject)
      |> Safe.one!()
    end

    def get_actor!(id, subject) do
      from(a in Domain.Actor, as: :actors)
      |> where([actors: a], a.id == ^id)
      |> Safe.scoped(subject)
      |> Safe.one!()
    end

    def search_actors(search_term, subject, exclude_actors) do
      exclude_ids = Enum.map(exclude_actors, & &1.id)
      search_pattern = "%#{search_term}%"

      case from(a in Domain.Actor, as: :actors)
           |> where(
             [actors: a],
             (ilike(a.name, ^search_pattern) or ilike(a.email, ^search_pattern)) and
               a.id not in ^exclude_ids
           )
           |> limit(10)
           |> Safe.scoped(subject)
           |> Safe.all() do
        actors when is_list(actors) -> actors
        {:error, _} -> []
      end
    end

    def get_group_with_actors!(id, subject) do
      query =
        from(g in Domain.Group, as: :groups)
        |> where([groups: groups], groups.id == ^id)
        |> join(:left, [groups: g], d in assoc(g, :directory), as: :directory)
        |> select_merge([groups: g, directory: d], %{
          directory_type: d.type
        })
        |> join(:left, [directory: d], gd in Domain.Google.Directory,
          on: gd.id == d.id and d.type == :google,
          as: :google_directory
        )
        |> join(:left, [directory: d], ed in Domain.Entra.Directory,
          on: ed.id == d.id and d.type == :entra,
          as: :entra_directory
        )
        |> join(:left, [directory: d], od in Domain.Okta.Directory,
          on: od.id == d.id and d.type == :okta,
          as: :okta_directory
        )
        |> join(:left, [groups: g], m in assoc(g, :memberships), as: :memberships)
        |> join(:left, [memberships: m], a in assoc(m, :actor), as: :actors)
        |> select_merge(
          [directory: d, google_directory: gd, entra_directory: ed, okta_directory: od],
          %{
            directory_name:
              fragment(
                "COALESCE(?, ?, ?)",
                gd.name,
                ed.name,
                od.name
              )
          }
        )
        |> preload([memberships: m, actors: a], memberships: m, actors: a)

      query |> Safe.scoped(subject) |> Safe.one!()
    end

    def preloads do
      []
    end

    def create(changeset, subject) do
      changeset
      |> Safe.scoped(subject)
      |> Safe.insert()
    end

    def update(changeset, subject) do
      changeset
      |> Safe.scoped(subject)
      |> Safe.update()
    end

    def delete(group, subject) do
      group
      |> Safe.scoped(subject)
      |> Safe.delete()
    end
  end
end
