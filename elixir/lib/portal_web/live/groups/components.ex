defmodule PortalWeb.Groups.Components do
  use PortalWeb, :component_library

  import PortalWeb.Policies.Components,
    only: [
      grant_condition_card: 1,
      available_conditions: 1,
      condition_type_label: 1
    ]

  attr :account, :any, required: true
  attr :group, :any, default: nil
  attr :flash, :map, required: true
  attr :query_params, :map, default: %{}
  attr :panel, :map, required: true
  attr :form_state, :map, required: true
  attr :members_state, :map, required: true
  attr :resources_state, :map, required: true
  attr :conditions_state, :map, required: true

  def group_panel(assigns) do
    assigns =
      assigns
      |> assign(assigns.panel)
      |> assign(assigns.form_state)
      |> assign(assigns.members_state)
      |> assign(assigns.resources_state)
      |> assign(assigns.conditions_state)

    ~H"""
    <div
      id="group-panel"
      class={[
        "absolute inset-y-0 right-0 z-10 flex flex-col w-full lg:w-3/4 xl:w-2/3",
        "bg-elevated border-l border-border-strong",
        "shadow-[-4px_0px_20px_rgba(0,0,0,0.07)]",
        "transition-transform duration-200 ease-in-out",
        if(@group || @view == :new_form, do: "translate-x-0", else: "translate-x-full")
      ]}
      phx-window-keydown="handle_keydown"
      phx-key="Escape"
    >
      <.group_form_view
        :if={@view in [:new_form, :edit_form]}
        account={@account}
        group={@group}
        flash={@flash}
        panel_view={@view}
        form={@form}
        members_to_add={@members_to_add}
        members_to_remove={@members_to_remove}
        member_search_results={@member_search_results}
      />

      <.group_details_view
        :if={@group && @view == :list}
        account={@account}
        group={@group}
        flash={@flash}
        panel={@panel}
        members_state={@members_state}
        resources_state={@resources_state}
        conditions_state={@conditions_state}
      />
    </div>
    """
  end

  attr :account, :any, required: true
  attr :group, :any, default: nil
  attr :flash, :map, required: true
  attr :panel_view, :atom, required: true
  attr :form, :any, required: true
  attr :members_to_add, :list, required: true
  attr :members_to_remove, :list, required: true
  attr :member_search_results, :any, default: nil

  def group_form_view(assigns) do
    assigns =
      assign(
        assigns,
        :current_members,
        if(assigns.panel_view == :edit_form && assigns.group,
          do: current_members_for_display(assigns.group, assigns.members_to_remove),
          else: []
        )
      )

    ~H"""
    <div class="flex flex-col h-full overflow-hidden">
      <div class="shrink-0 px-5 pt-4 pb-3 border-b border-border bg-elevated">
        <div class="flex items-center justify-between gap-3">
          <div class="flex items-center gap-2 min-w-0">
            <.link
              :if={@panel_view == :edit_form && @group}
              patch={~p"/#{@account}/groups/#{@group.id}"}
              class="flex items-center justify-center w-7 h-7 rounded text-subtle hover:text-heading hover:bg-raised transition-colors shrink-0"
              title="Back to group"
            >
              <.icon name="ri-arrow-left-line" class="w-4 h-4" />
            </.link>
            <h2 class="text-sm font-semibold text-heading truncate">
              {if @panel_view == :new_form, do: "New Group", else: "Edit #{@group && @group.name}"}
            </h2>
          </div>
          <.icon_button icon="ri-close-line" title="Close (Esc)" phx-click="close_panel" class="shrink-0" />
        </div>
      </div>
      <.form
        id="group-form"
        for={@form}
        phx-change="validate"
        phx-submit={if @panel_view == :new_form, do: "create", else: "save"}
        class="flex flex-col flex-1 min-h-0 overflow-hidden"
      >
        <div class="flex-1 overflow-y-auto px-5 py-4 space-y-4">
          <.flash id="group-success-inline" kind={:success_inline} style="inline" flash={@flash} />
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
            <h3 class="text-sm font-medium text-body mb-2">
              {if @panel_view == :edit_form,
                do: "Members (#{length(@current_members) + length(@members_to_add)})",
                else: "Members (#{length(@members_to_add)})"}
            </h3>
            <.member_search_input form={@form} member_search_results={@member_search_results} />
            <div class="grid gap-2 mt-2 lg:grid-cols-3">
              <.member_bucket
                title="Current"
                count={length(@current_members)}
                members={@current_members}
                empty_message="No current members."
              >
                <:badge :let={actor}>
                  <.actor_type_badge actor={actor} />
                </:badge>
                <:actions :let={actor}>
                  <button
                    type="button"
                    phx-click="remove_member"
                    phx-value-actor_id={actor.id}
                    class="shrink-0 text-subtle hover:text-error transition-colors"
                    title="Remove from current members"
                  >
                    <.icon name="ri-close-line" class="w-4 h-4" />
                  </button>
                </:actions>
              </.member_bucket>

              <.member_bucket
                title="To Add"
                title_class="text-green-700"
                count={length(@members_to_add)}
                members={@members_to_add}
                empty_message="No pending additions."
              >
                <:badge :let={actor}>
                  <.actor_type_badge actor={actor} />
                </:badge>
                <:actions :let={actor}>
                  <button
                    type="button"
                    phx-click="remove_member"
                    phx-value-actor_id={actor.id}
                    class="shrink-0 text-subtle hover:text-error transition-colors"
                    title="Remove from pending additions"
                  >
                    <.icon name="ri-close-line" class="w-4 h-4" />
                  </button>
                </:actions>
              </.member_bucket>

              <.member_bucket
                title="To Remove"
                title_class="text-red-700"
                count={length(@members_to_remove)}
                members={@members_to_remove}
                empty_message="No pending removals."
              >
                <:badge :let={actor}>
                  <.actor_type_badge actor={actor} />
                </:badge>
                <:actions :let={actor}>
                  <button
                    type="button"
                    phx-click="undo_member_removal"
                    phx-value-actor_id={actor.id}
                    class="shrink-0 text-subtle hover:text-heading transition-colors"
                    title="Remove from pending removals"
                  >
                    <.icon name="ri-close-line" class="w-4 h-4" />
                  </button>
                </:actions>
              </.member_bucket>
            </div>
          </div>
        </div>
        <div class="shrink-0 flex items-center justify-end gap-2 px-5 py-3 border-t border-border bg-elevated">
          <.link
            patch={
              if @panel_view == :edit_form && @group,
                do: ~p"/#{@account}/groups/#{@group.id}",
                else: ~p"/#{@account}/groups"
            }
            class="px-3 py-1.5 text-xs rounded border border-border-strong text-body hover:text-heading hover:border-border-emphasis bg-surface transition-colors"
          >
            Cancel
          </.link>
          <.button
            type="submit"
            style="primary"
            disabled={
              if @panel_view == :new_form,
                do: not @form.source.valid?,
                else: edit_form_unchanged?(@form, @members_to_add, @members_to_remove)
            }
            size="sm"
            class="font-medium"
          >
            {if @panel_view == :new_form, do: "Create Group", else: "Save Changes"}
          </.button>
        </div>
      </.form>
    </div>
    """
  end

  attr :account, :any, required: true
  attr :group, :any, required: true
  attr :flash, :map, required: true
  attr :panel, :map, required: true
  attr :members_state, :map, required: true
  attr :resources_state, :map, required: true
  attr :conditions_state, :map, required: true

  def group_details_view(assigns) do
    assigns =
      assigns
      |> assign(assigns.panel)
      |> assign(assigns.members_state)
      |> assign(assigns.resources_state)
      |> assign(assigns.conditions_state)

    ~H"""
    <div class="flex flex-col h-full overflow-hidden">
      <.group_details_header account={@account} group={@group} confirm_delete?={@confirm_delete?} />

      <div class="flex flex-1 min-h-0 divide-x divide-border">
        <div class="flex-1 flex flex-col overflow-hidden">
          <.group_tabs
            tab={@tab}
            tab_view={@tab_view}
            member_total={@member_total}
            resources_count={length(@resources)}
            show_member_filter={@show_member_filter}
          />

          <.group_members_tab
            :if={@tab == :members}
            account={@account}
            flash={@flash}
            panel_members={@panel_members}
            member_total={@member_total}
            member_pages={@member_pages}
            member_page={@member_page}
            show_member_filter={@show_member_filter}
          />

          <.group_resources_tab
            :if={@tab == :resources}
            account={@account}
            resources_state={@resources_state}
            conditions_state={@conditions_state}
          />
        </div>

        <.group_sidebar group={@group} confirm_delete?={@confirm_delete?} />
      </div>
    </div>
    """
  end

  attr :account, :any, required: true
  attr :group, :any, required: true
  attr :confirm_delete?, :boolean, required: true

  def group_details_header(assigns) do
    ~H"""
    <div class="shrink-0 px-5 py-4 border-b border-border bg-elevated">
      <div class="flex items-center gap-4">
        <%!-- Left: icon + name + directory info --%>
        <div class="flex items-center gap-3 min-w-0 flex-1">
          <.provider_icon provider={provider_type_from_group(@group)} size="lg" variant="circle" />
          <div class="min-w-0">
            <h2 class="text-sm font-semibold text-heading truncate">
              {@group.name}
            </h2>
            <div class="flex items-center gap-1.5 mt-0.5">
              <span
                :if={@group.entity_type == :org_unit}
                class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-neutral-status-light text-subtle"
              >
                OU
              </span>
              <span class="text-xs text-subtle">
                {directory_display_name(@group.directory)}
              </span>
            </div>
          </div>
        </div>
        <%!-- Right: actions --%>
        <div class="flex items-center gap-1.5 shrink-0">
          <.link
            :if={editable_group?(@group) and not @confirm_delete?}
            patch={~p"/#{@account}/groups/#{@group.id}/edit"}
            class="flex items-center gap-1 px-2.5 py-1.5 rounded text-xs border border-border-strong text-body hover:text-heading hover:border-border-emphasis bg-surface transition-colors"
          >
            <.icon name="ri-pencil-line" class="w-3.5 h-3.5" /> Edit
          </.link>
          <.icon_button icon="ri-close-line" title="Close (Esc)" phx-click="close_panel" />
        </div>
      </div>
    </div>
    """
  end

  attr :tab, :atom, required: true
  attr :tab_view, :atom, required: true
  attr :member_total, :integer, required: true
  attr :resources_count, :integer, required: true
  attr :show_member_filter, :string, required: true

  def group_tabs(assigns) do
    ~H"""
    <div class="flex items-end gap-0 px-5 border-b border-border bg-raised shrink-0">
      <button
        phx-click="switch_group_tab"
        phx-value-tab="members"
        class={[
          "flex items-center gap-1.5 px-1 py-2.5 mr-5 text-xs font-medium border-b-2 transition-colors",
          if(@tab == :members,
            do: "border-brand text-brand",
            else:
              "border-transparent text-body hover:text-heading hover:border-border-strong"
          )
        ]}
      >
        Members
        <span class={[
          "tabular-nums px-1.5 py-0.5 rounded text-[10px] font-semibold",
          if(@tab == :members,
            do: "bg-brand-muted text-brand",
            else: "bg-raised text-subtle"
          )
        ]}>
          {@member_total}
        </span>
      </button>
      <button
        phx-click="switch_group_tab"
        phx-value-tab="resources"
        class={[
          "flex items-center gap-1.5 px-1 py-2.5 mr-5 text-xs font-medium border-b-2 transition-colors",
          if(@tab == :resources,
            do: "border-brand text-brand",
            else:
              "border-transparent text-body hover:text-heading hover:border-border-strong"
          )
        ]}
      >
        Resources
        <span class={[
          "tabular-nums px-1.5 py-0.5 rounded text-[10px] font-semibold",
          if(@tab == :resources,
            do: "bg-brand-muted text-brand",
            else: "bg-raised text-subtle"
          )
        ]}>
          {@resources_count}
        </span>
      </button>
      <div :if={@tab == :resources && @tab_view == :list} class="ml-auto pb-2 flex items-center">
        <.button type="button" phx-click="open_grant_resource_form" size="xs">
          <.icon name="ri-add-line" class="w-3 h-3" /> Grant access
        </.button>
      </div>
      <div :if={@tab == :members} class="ml-auto pb-2 flex items-center">
        <form phx-change="filter_show_members">
          <div class="relative">
            <.icon
              name="ri-search-line"
              class="absolute left-2 top-1/2 -translate-y-1/2 w-3 h-3 text-subtle"
            />
            <input
              type="text"
              value={@show_member_filter}
              placeholder="Filter..."
              phx-debounce="300"
              name="filter"
              autocomplete="off"
              data-1p-ignore
              class="pl-6 pr-2 py-1 text-xs rounded border bg-input border-input-border text-heading placeholder:text-muted outline-none focus:border-border-focus focus:ring-1 focus:ring-border-focus/30 transition-colors w-32"
            />
          </div>
        </form>
      </div>
    </div>
    """
  end

  attr :account, :any, required: true
  attr :flash, :map, required: true
  attr :panel_members, :list, required: true
  attr :member_total, :integer, required: true
  attr :member_pages, :integer, required: true
  attr :member_page, :integer, required: true
  attr :show_member_filter, :string, required: true

  def group_members_tab(assigns) do
    ~H"""
    <div class="flex-1 flex flex-col overflow-hidden">
      <.flash id="group-success-inline-show" kind={:success_inline} style="inline" flash={@flash} />
      <div class="flex-1 overflow-y-auto">
        <div
          :if={@panel_members == [] && @member_total == 0}
          class="flex items-center justify-center py-16"
        >
          <p class="text-sm text-subtle">
            <%= if has_content?(@show_member_filter) do %>
              No members match your filter.
            <% else %>
              No members in this group.
            <% end %>
          </p>
        </div>
        <ul :if={@panel_members != []} class="divide-y divide-border">
          <li :for={actor <- @panel_members} class="transition-colors">
            <.link
              navigate={~p"/#{@account}/actors/#{actor.id}"}
              class="flex items-center gap-3 px-5 py-3 hover:bg-raised"
            >
              <.actor_type_badge actor={actor} />
              <div class="flex-1 min-w-0">
                <p class="text-sm font-medium text-heading truncate">
                  {actor.name}
                </p>
                <p
                  :if={actor.email || actor.type == :service_account}
                  class="text-xs text-subtle truncate"
                >
                  {actor.email || "(Service Account)"}
                </p>
              </div>
            </.link>
          </li>
        </ul>
      </div>
      <div
        :if={@member_pages > 1}
        class="shrink-0 flex items-center justify-between px-5 py-2.5 border-t border-border bg-raised"
      >
        <span class="text-xs text-subtle">
          Page {@member_page} of {@member_pages}
          <span class="text-muted">({@member_total} members)</span>
        </span>
        <div class="flex items-center gap-1">
          <.icon_button
            style="outline"
            icon="ri-arrow-left-s-line"
            title="Previous page"
            phx-click="prev_member_page"
            disabled={@member_page <= 1}
          />
          <.icon_button
            style="outline"
            icon="ri-arrow-right-s-line"
            title="Next page"
            phx-click="next_member_page"
            disabled={@member_page >= @member_pages}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :account, :any, required: true
  attr :resources_state, :map, required: true
  attr :conditions_state, :map, required: true

  def group_resources_tab(assigns) do
    assigns =
      assigns
      |> assign(assigns.resources_state)
      |> assign(assigns.conditions_state)

    ~H"""
    <div class="flex-1 flex flex-col overflow-hidden">
      <.group_grant_resource_form
        :if={@tab_view == :grant_form}
        resources_state={@resources_state}
        conditions_state={@conditions_state}
      />

      <.group_resources_list
        :if={@tab_view != :grant_form}
        account={@account}
        resources={@resources}
        resource_access_actions_open_id={@resource_access_actions_open_id}
        confirm_remove_resource_access_id={@confirm_remove_resource_access_id}
      />
    </div>
    """
  end

  attr :resources_state, :map, required: true
  attr :conditions_state, :map, required: true

  def group_grant_resource_form(assigns) do
    assigns =
      assigns
      |> assign(assigns.resources_state)
      |> assign(assigns.conditions_state)

    assigns =
      assign(assigns, :conditions_state, %{
        timezone: assigns.conditions_state.timezone,
        location_search: assigns.conditions_state.location_search,
        location_operator: assigns.conditions_state.location_operator,
        location_values: assigns.conditions_state.location_values,
        ip_range_operator: assigns.conditions_state.ip_range_operator,
        ip_range_values: assigns.conditions_state.ip_range_values,
        ip_range_input: assigns.conditions_state.ip_range_input,
        auth_provider_operator: assigns.conditions_state.auth_provider_operator,
        auth_provider_values: assigns.conditions_state.auth_provider_values,
        tod_values: assigns.conditions_state.tod_values,
        tod_adding: assigns.conditions_state.tod_adding?,
        tod_pending: assigns.conditions_state.tod_pending,
        tod_pending_error: assigns.conditions_state.tod_pending_error
      })

    ~H"""
    <div class="flex items-center justify-between px-5 py-2.5 border-b border-border bg-raised shrink-0">
      <div class="flex items-center gap-2">
        <button
          type="button"
          phx-click="close_grant_resource_form"
          class="flex items-center justify-center w-5 h-5 rounded text-subtle hover:text-heading hover:bg-surface transition-colors"
          title="Back to resource list"
        >
          <.icon name="ri-arrow-left-s-line" class="w-3.5 h-3.5" />
        </button>
        <span class="text-xs font-semibold text-heading">Grant access</span>
      </div>
    </div>
    <.form
      for={@grant_resource_form}
      phx-submit="submit_grant_resource"
      id="grant-resource-form"
      class="flex-1 flex flex-col overflow-hidden"
    >
      <div class="flex-1 overflow-y-auto">
        <div class="px-5 py-4 space-y-5">
          <div>
            <label class="block text-xs font-medium text-body mb-2">
              Resources <span class="text-error">*</span>
            </label>
            <% filtered_available =
              @available_resources
              |> Enum.reject(&(&1.id in @grant_selected_resource_ids))
              |> then(fn resources ->
                if @grant_resource_search == "" do
                  resources
                else
                  Enum.filter(resources, fn r ->
                    String.contains?(
                      String.downcase(r.name),
                      String.downcase(@grant_resource_search)
                    ) or
                      String.contains?(
                        String.downcase(r.address || ""),
                        String.downcase(@grant_resource_search)
                      )
                  end)
                end
              end)
              selected_resources =
                Enum.filter(@available_resources, &(&1.id in @grant_selected_resource_ids))
              %>
            <div class="flex gap-2 h-52">
              <div class="flex-1 flex flex-col min-w-0 rounded border border-border overflow-hidden">
                <div class="flex items-center justify-between px-2.5 py-1.5 border-b border-border bg-raised shrink-0">
                  <span class="text-[10px] font-semibold uppercase tracking-wider text-subtle">
                    Available
                  </span>
                  <span class="text-[10px] text-muted">
                    {length(filtered_available)}
                  </span>
                </div>
                <div class="px-2 pt-1.5 shrink-0">
                  <div class="relative">
                    <.icon
                      name="ri-search-line"
                      class="absolute left-2 top-1/2 -translate-y-1/2 w-3 h-3 text-subtle pointer-events-none"
                    />
                    <input
                      type="text"
                      placeholder="Search…"
                      value={@grant_resource_search}
                      phx-keyup="search_grant_resources"
                      phx-debounce="200"
                      autocomplete="off"
                      data-1p-ignore
                      class="w-full pl-6 pr-2 py-1 text-xs rounded border border-border bg-surface text-heading placeholder:text-muted outline-none focus:border-border-focus focus:ring-1 focus:ring-border-focus/30 transition-colors"
                    />
                  </div>
                </div>
                <ul class="flex-1 overflow-y-auto px-2 py-1.5 space-y-0.5">
                  <li :for={resource <- filtered_available}>
                    <button
                      type="button"
                      phx-click="toggle_grant_resource"
                      phx-value-resource_id={resource.id}
                      class="flex items-center gap-2 px-2 py-1.5 w-full rounded text-left transition-colors hover:bg-surface cursor-pointer"
                    >
                      <div class="flex-1 min-w-0">
                        <p class="text-xs text-heading truncate">{resource.name}</p>
                        <p class="text-[10px] text-subtle font-mono truncate">
                          {resource.address}
                        </p>
                      </div>
                    </button>
                  </li>
                  <li
                    :if={@available_resources == []}
                    class="flex items-center justify-center h-16 text-xs text-subtle"
                  >
                    All resources already have access.
                  </li>
                  <li
                    :if={@available_resources != [] && filtered_available == []}
                    class="flex items-center justify-center h-12 text-xs text-subtle"
                  >
                    No resources match.
                  </li>
                </ul>
              </div>
              <div class="flex-1 flex flex-col min-w-0 rounded border border-border overflow-hidden">
                <div class="flex items-center justify-between px-2.5 py-1.5 border-b border-border bg-raised shrink-0">
                  <span class="text-[10px] font-semibold uppercase tracking-wider text-subtle">
                    Selected
                  </span>
                  <span class="text-[10px] font-medium text-muted">
                    {length(@grant_selected_resource_ids)}
                  </span>
                </div>
                <ul class="flex-1 overflow-y-auto px-2 py-1.5 space-y-0.5">
                  <li :for={resource <- selected_resources}>
                    <button
                      type="button"
                      phx-click="toggle_grant_resource"
                      phx-value-resource_id={resource.id}
                      class="flex items-center gap-2 px-2 py-1.5 w-full rounded text-left hover:bg-surface transition-colors cursor-pointer group"
                    >
                      <div class="flex-1 min-w-0">
                        <p class="text-xs text-heading truncate">{resource.name}</p>
                        <p class="text-[10px] text-subtle font-mono truncate">
                          {resource.address}
                        </p>
                      </div>
                      <.icon
                        name="ri-close-line"
                        class="w-3.5 h-3.5 text-subtle opacity-0 group-hover:opacity-100 shrink-0 transition-opacity"
                      />
                    </button>
                  </li>
                  <li
                    :if={selected_resources == []}
                    class="flex items-center justify-center h-16 text-xs text-subtle"
                  >
                    No resources selected.
                  </li>
                </ul>
              </div>
            </div>
          </div>
          <% allowed_conditions =
            case @grant_selected_resource_ids do
              [] ->
                []

              ids ->
                ids
                |> Enum.map(fn id -> Enum.find(@available_resources, &(&1.id == id)) end)
                |> Enum.reject(&is_nil/1)
                |> Enum.map(&available_conditions/1)
                |> Enum.reduce(&Enum.filter(&2, fn c -> c in &1 end))
            end %>
          <div class="border-t border-border pt-4">
            <div class="flex items-center justify-between mb-3">
              <h4 class="text-[10px] font-semibold tracking-widest uppercase text-subtle">
                Conditions
                <span class="ml-1 font-normal normal-case tracking-normal text-muted">
                  (optional)
                </span>
              </h4>
              <div
                :if={allowed_conditions -- @active_conditions != []}
                class="relative"
              >
                <button
                  type="button"
                  phx-click="toggle_conditions_dropdown"
                  class="flex items-center gap-1 px-2 py-1 rounded text-[10px] border border-border-strong text-body hover:text-heading hover:border-border-emphasis bg-surface transition-colors"
                >
                  <.icon name="ri-add-line" class="w-2.5 h-2.5" /> Add condition
                </button>
                <div :if={@conditions_dropdown_open?}>
                  <div class="fixed inset-0 z-10" phx-click="toggle_conditions_dropdown"></div>
                  <div class="absolute right-0 top-full mt-1 z-20 min-w-44 rounded-lg border border-border-strong bg-elevated shadow-lg py-1 overflow-hidden">
                    <button
                      :for={type <- allowed_conditions -- @active_conditions}
                      type="button"
                      phx-click="add_condition"
                      phx-value-type={type}
                      class="w-full text-left px-3 py-1.5 text-xs text-body hover:text-heading hover:bg-raised transition-colors"
                    >
                      {condition_type_label(type)}
                    </button>
                  </div>
                </div>
              </div>
            </div>
            <p
              :if={@active_conditions == []}
              class="text-xs text-muted text-center py-4 rounded-lg border border-dashed border-border"
            >
              No conditions - access is unrestricted
            </p>
            <div class="space-y-2">
              <.grant_condition_card
                :for={type <- @active_conditions}
                type={type}
                providers={@providers}
                conditions_state={@conditions_state}
              />
            </div>
          </div>
        </div>
      </div>
      <div
        :if={@grant_resource_form && @grant_resource_form.errors != []}
        class="px-5 py-2 text-xs text-error"
      >
        <p :for={{_field, {msg, _}} <- @grant_resource_form.errors}>{msg}</p>
      </div>
      <div class="shrink-0 flex items-center justify-end gap-2 px-5 py-3 border-t border-border bg-elevated">
        <.button type="button" phx-click="close_grant_resource_form" size="xs">
          Cancel
        </.button>
        <.button type="submit" style="primary" disabled={@grant_selected_resource_ids == []} size="xs">
          Grant access
        </.button>
      </div>
    </.form>
    """
  end

  attr :account, :any, required: true
  attr :resources, :list, required: true
  attr :resource_access_actions_open_id, :any, default: nil
  attr :confirm_remove_resource_access_id, :any, default: nil

  def group_resources_list(assigns) do
    ~H"""
    <div class="flex-1 overflow-y-auto">
      <div
        :if={@resources == []}
        class="flex flex-col items-center justify-center h-full py-12 text-center"
      >
        <p class="text-sm font-medium text-body">No resource access</p>
        <p class="text-xs text-subtle mt-1">
          Assign a policy to grant this group access.
        </p>
      </div>
      <ul :if={@resources != []}>
        <li
          :for={row <- @resources}
          class={[
            "border-b border-border transition-colors",
            @confirm_remove_resource_access_id == row.resource.id &&
              "bg-error-light border-error/20"
          ]}
        >
          <div
            :if={@confirm_remove_resource_access_id == row.resource.id}
            class="flex items-center justify-between gap-2 px-4 py-2.5"
          >
            <span class="text-xs text-body truncate">
              Remove access to <span class="font-medium text-heading">{row.resource.name}</span>?
              <span class="block text-subtle">
                All group members will immediately lose access.
              </span>
            </span>
            <div class="flex items-center gap-1.5 shrink-0">
              <.button type="button" phx-click="cancel_remove_resource_access" size="xs">
                Cancel
              </.button>
              <.button
                type="button"
                phx-click="remove_resource_access"
                phx-value-resource_id={row.resource.id}
                style="danger"
                size="xs"
              >
                Remove
              </.button>
            </div>
          </div>
          <div
            :if={@confirm_remove_resource_access_id != row.resource.id}
            class={[
              "flex items-center gap-1 pr-4 hover:bg-raised group/item",
              @resource_access_actions_open_id == row.resource.id && "relative z-20"
            ]}
          >
            <.link
              navigate={~p"/#{@account}/resources/#{row.resource.id}"}
              class={[
                "flex items-center gap-3 px-5 py-3 flex-1 min-w-0",
                not is_nil(row.policy_disabled_at) && "opacity-50 hover:opacity-75"
              ]}
            >
              <div class="w-14 shrink-0 flex">
                <span class={type_badge_class(row.resource.type)}>
                  {row.resource.type}
                </span>
              </div>
              <div class="flex-1 min-w-0">
                <div class="flex items-center gap-2">
                  <p class="text-sm font-medium text-heading group-hover/item:text-brand transition-colors truncate">
                    {row.resource.name}
                  </p>
                  <span
                    :if={not is_nil(row.policy_disabled_at)}
                    class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-neutral-status-light text-subtle shrink-0"
                  >
                    disabled
                  </span>
                </div>
                <span class="text-xs text-subtle font-mono truncate block">
                  {row.resource.address}
                </span>
              </div>
            </.link>
            <.actions_dropdown
              open={@resource_access_actions_open_id == row.resource.id}
              close_event="close_resource_access_actions"
              button_class="flex items-center justify-center w-6 h-6 rounded text-subtle hover:text-heading hover:bg-surface transition-colors"
              icon_class="w-3.5 h-3.5"
              phx-click="toggle_resource_access_actions"
              phx-value-resource_id={row.resource.id}
              title="More actions"
            >
              <button
                :if={is_nil(row.policy_disabled_at)}
                type="button"
                phx-click="disable_resource_access"
                phx-value-resource_id={row.resource.id}
                class="flex items-center gap-2 w-full px-3 py-1.5 text-xs text-body hover:text-heading hover:bg-raised transition-colors"
              >
                <.icon name="ri-pause-line" class="w-3.5 h-3.5 shrink-0" /> Disable
              </button>
              <button
                :if={not is_nil(row.policy_disabled_at)}
                type="button"
                phx-click="enable_resource_access"
                phx-value-resource_id={row.resource.id}
                class="flex items-center gap-2 w-full px-3 py-1.5 text-xs text-body hover:text-heading hover:bg-raised transition-colors"
              >
                <.icon name="ri-play-line" class="w-3.5 h-3.5 shrink-0" /> Enable
              </button>
              <button
                type="button"
                phx-click="confirm_remove_resource_access"
                phx-value-resource_id={row.resource.id}
                class="flex items-center gap-2 w-full px-3 py-1.5 text-xs text-error hover:bg-raised transition-colors"
              >
                <.icon name="ri-delete-bin-line" class="w-3.5 h-3.5 shrink-0" /> Remove access
              </button>
            </.actions_dropdown>
          </div>
        </li>
      </ul>
    </div>
    """
  end

  attr :group, :any, required: true
  attr :confirm_delete?, :boolean, required: true

  def group_sidebar(assigns) do
    ~H"""
    <div class="w-1/3 shrink-0 overflow-y-auto p-4 space-y-5">
      <section>
        <h3 class="text-[10px] font-semibold tracking-widest uppercase text-subtle mb-3">
          Details
        </h3>
        <dl class="space-y-2.5">
          <div>
            <dt class="text-[10px] text-subtle mb-0.5">ID</dt>
            <dd class="font-mono text-[11px] text-body break-all">
              {@group.id}
            </dd>
          </div>
          <div>
            <dt class="text-[10px] text-subtle mb-0.5">Name</dt>
            <dd class="text-xs text-body truncate" title={@group.name}>
              {@group.name}
            </dd>
          </div>
          <div>
            <dt class="text-[10px] text-subtle mb-0.5">Directory</dt>
            <dd class="text-xs text-body">
              {directory_display_name(@group.directory)}
            </dd>
          </div>
          <div :if={@group.entity_type == :org_unit}>
            <dt class="text-[10px] text-subtle mb-0.5">Type</dt>
            <dd class="text-xs text-body">Org Unit</dd>
          </div>
          <div>
            <dt class="text-[10px] text-subtle mb-0.5">Created</dt>
            <dd class="text-xs text-body mt-0.5">
              <.relative_datetime datetime={@group.inserted_at} />
            </dd>
          </div>
          <div>
            <dt class="text-[10px] text-subtle mb-0.5">Updated</dt>
            <dd class="text-xs text-body mt-0.5">
              <.relative_datetime datetime={@group.updated_at} />
            </dd>
          </div>
          <div :if={Ecto.assoc_loaded?(@group.sync_state) && @group.sync_state && @group.sync_state.synced_at}>
            <dt class="text-[10px] text-subtle mb-0.5">Last Synced</dt>
            <dd class="text-xs text-body mt-0.5">
              <.relative_datetime datetime={@group.sync_state.synced_at} />
            </dd>
          </div>
          <div :if={@group.idp_id && get_idp_id(@group.idp_id)}>
            <dt class="text-[10px] text-subtle mb-0.5">IDP ID</dt>
            <dd
              class="font-mono text-[11px] text-body break-all mt-0.5"
              title={get_idp_id(@group.idp_id)}
            >
              {get_idp_id(@group.idp_id)}
            </dd>
          </div>
        </dl>
      </section>
      <div :if={deletable_group?(@group)} class="border-t border-border"></div>
      <section :if={deletable_group?(@group)}>
        <h3 class="text-[10px] font-semibold tracking-widest uppercase text-error/60 mb-3">
          Danger Zone
        </h3>
        <button
          :if={not @confirm_delete?}
          type="button"
          phx-click="confirm_delete_group"
          class="w-full flex items-center gap-2 px-3 py-2 rounded border border-error/20 text-xs text-error hover:bg-error-light transition-colors"
        >
          <.icon name="ri-delete-bin-line" class="w-4 h-4 shrink-0" /> Delete group
        </button>
        <div
          :if={@confirm_delete?}
          class="px-3 py-2.5 rounded border border-error/20 bg-error-light"
        >
          <p class="text-xs font-medium text-error mb-1">
            Delete this group?
          </p>
          <p class="text-xs text-error/70 mb-3">
            All associated policies will also be deleted and clients will immediately lose access.
          </p>
          <div class="flex items-center gap-1.5">
            <.button type="button" phx-click="cancel_delete_group" size="xs">
              Cancel
            </.button>
            <.button
              type="button"
              phx-click="delete"
              phx-value-id={@group.id}
              style="danger"
              size="xs"
            >
              Delete
            </.button>
          </div>
        </div>
      </section>
    </div>
    """
  end

  attr :actor, :any, required: true
  attr :class, :string, default: "w-7 h-7"

  defp actor_type_badge(assigns) do
    ~H"""
    <div class={[
      "inline-flex items-center justify-center rounded-full shrink-0",
      @class,
      actor_type_icon_bg_color(@actor.type)
    ]}>
      <%= case @actor.type do %>
        <% :service_account -> %>
          <.icon
            name="ri-server-line"
            class={"w-4 h-4 #{actor_type_icon_text_color(@actor.type)}"}
          />
        <% :account_admin_user -> %>
          <.icon
            name="ri-shield-check-line"
            class={"w-4 h-4 #{actor_type_icon_text_color(@actor.type)}"}
          />
        <% _ -> %>
          <.icon name="ri-user-line" class={"w-4 h-4 #{actor_type_icon_text_color(@actor.type)}"} />
      <% end %>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :member_search_results, :any, default: nil
  attr :placeholder, :string, default: "Search to add members..."

  defp member_search_input(assigns) do
    ~H"""
    <div
      class="p-3 bg-raised border-b border-border relative"
      phx-click-away="blur_search"
    >
      <div class="relative">
        <.icon
          name="ri-search-line"
          class="absolute left-2.5 top-1/2 -translate-y-1/2 w-3 h-3 text-subtle pointer-events-none"
        />
        <input
          type="text"
          name={@form[:member_search].name}
          value={@form[:member_search].value}
          placeholder={@placeholder}
          phx-debounce="300"
          phx-focus="focus_search"
          autocomplete="off"
          data-1p-ignore
          class="w-full pl-7 pr-3 py-1.5 text-xs rounded border border-border bg-surface text-heading placeholder:text-muted outline-none focus:border-border-focus focus:ring-1 focus:ring-border-focus/30 transition-colors"
        />
      </div>

      <div
        :if={@member_search_results != nil}
        class="absolute z-10 left-3 right-3 mt-1 bg-elevated border border-border rounded-lg shadow-lg max-h-48 overflow-y-auto"
      >
        <button
          :for={actor <- @member_search_results}
          type="button"
          phx-click="add_member"
          phx-value-actor_id={actor.id}
          class="w-full text-left px-3 py-2 hover:bg-raised border-b border-border last:border-b-0 transition-colors"
        >
          <div class="space-y-0.5">
            <div class="flex items-center gap-2">
              <.actor_type_badge actor={actor} />
              <div class="text-xs font-medium text-heading">{actor.name}</div>
            </div>
            <div :if={actor.email} class="text-xs text-subtle pl-9">
              {actor.email}
            </div>
          </div>
        </button>
        <div
          :if={@member_search_results == []}
          class="px-3 py-4 text-center text-xs text-subtle"
        >
          No members found
        </div>
      </div>
    </div>
    """
  end

  attr :members, :list, required: true
  attr :title, :string, required: true
  attr :count, :integer, required: true
  attr :title_class, :string, default: nil
  attr :empty_message, :string, required: true
  slot :badge
  slot :actions

  defp member_bucket(assigns) do
    ~H"""
    <section class="min-w-0 rounded border border-border bg-surface overflow-hidden">
      <div class="flex items-center justify-between px-2.5 py-1.5 border-b border-border bg-raised shrink-0">
        <h4 class={["text-[10px] font-semibold uppercase tracking-wider", @title_class || "text-subtle"]}>
          {@title}
        </h4>
        <span class="text-[10px] text-muted">{@count}</span>
      </div>
      <.member_list
        members={@members}
        item_class="px-2 py-1.5 flex items-center justify-between gap-2 rounded group hover:bg-surface transition-colors"
        list_class="h-48 overflow-y-auto px-2 py-1.5 space-y-0.5"
        empty_class="flex items-center justify-center h-16"
      >
        <:badge :let={actor}>{render_slot(@badge, actor)}</:badge>
        <:actions :let={actor}>{render_slot(@actions, actor)}</:actions>
        <:empty_message>{@empty_message}</:empty_message>
      </.member_list>
    </section>
    """
  end

  attr :members, :list, required: true
  attr :item_class, :string, default: "px-3 py-2.5 flex items-center justify-between group"
  attr :list_class, :string, default: "divide-y divide-border h-48 overflow-y-auto"
  attr :empty_class, :string, default: "flex items-center justify-center h-64"
  slot :badge
  slot :actions
  slot :empty_message, required: true

  defp member_list(assigns) do
    assigns = assign(assigns, :has_actions, assigns.actions != [])

    ~H"""
    <ul :if={@members != []} class={@list_class}>
      <li :for={actor <- @members} class={@item_class}>
        <div class={["flex items-center gap-3", @has_actions && "flex-1 min-w-0"]}>
          <%= if @badge != [] do %>
            {render_slot(@badge, actor)}
          <% end %>
          <div class={@has_actions && "flex-1 min-w-0"}>
            <p class={["text-xs font-medium text-heading", @has_actions && "truncate"]}>
              {actor.name}
            </p>
            <p
              :if={actor.email}
              class={["text-xs text-subtle", @has_actions && "truncate"]}
            >
              {actor.email}
            </p>
          </div>
        </div>
        <%= if @has_actions do %>
          {render_slot(@actions, actor)}
        <% end %>
      </li>
    </ul>

    <div :if={@members == []} class={@empty_class}>
      <p class="text-xs text-subtle">
        {render_slot(@empty_message)}
      </p>
    </div>
    """
  end

  defp actor_type_icon_bg_color(:service_account), do: "bg-blue-100"
  defp actor_type_icon_bg_color(:account_admin_user), do: "bg-purple-100"
  defp actor_type_icon_bg_color(_), do: "bg-neutral-100"

  defp actor_type_icon_text_color(:service_account), do: "text-blue-800"
  defp actor_type_icon_text_color(:account_admin_user), do: "text-purple-800"
  defp actor_type_icon_text_color(_), do: "text-neutral-800"

  defp editable_group?(%{type: :managed, name: "Everyone"}), do: false
  defp editable_group?(%{idp_id: nil}), do: true
  defp editable_group?(_group), do: false

  defp deletable_group?(%{name: "Everyone"}), do: false
  defp deletable_group?(_group), do: true

  defp directory_display_name(directory) do
    case directory do
      %{google_directory: %{name: name}} when not is_nil(name) -> name
      %{entra_directory: %{name: name}} when not is_nil(name) -> name
      %{okta_directory: %{name: name}} when not is_nil(name) -> name
      _ -> "Firezone"
    end
  end

  defp type_badge_class(:dns),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-badge-dns text-badge-dns-text"

  defp type_badge_class(:ip),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-badge-ip text-badge-ip-text"

  defp type_badge_class(:cidr),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-badge-cidr text-badge-cidr-text"

  defp type_badge_class(:internet),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-violet-100 text-violet-700 dark:bg-violet-900/30 dark:text-violet-300"

  defp type_badge_class(_),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-raised text-body"

  defp get_idp_id(idp_id) do
    case String.split(idp_id, ":", parts: 2) do
      [_provider, actual_id] -> actual_id
      _ -> idp_id
    end
  end

  defp has_content?(str), do: String.trim(str) != ""

  defp edit_form_unchanged?(form, members_to_add, members_to_remove) do
    not form.source.valid? or
      (Enum.empty?(form.source.changes) and members_to_add == [] and members_to_remove == [])
  end

  defp current_members_for_display(group, members_to_remove) do
    remove_ids = MapSet.new(members_to_remove, & &1.id)
    Enum.reject(group.actors, &MapSet.member?(remove_ids, &1.id))
  end
end
