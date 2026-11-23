defmodule PortalWeb.Groups.Components do
  use PortalWeb, :component_library

  alias PortalWeb.Actors
  alias PortalWeb.Policies

  attr :account, :any, required: true
  attr :group, :any, default: nil
  attr :flash, :map, required: true
  attr :edit_path, :string, default: nil
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

    ~H"""
    <Page.detail_modal
      id="group-panel"
      open={not is_nil(@group) or @view == :new_form}
      on_close="handle_keydown"
      size="xl"
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
        edit_path={@edit_path}
        flash={@flash}
        panel={@panel}
        members_state={@members_state}
        resources_state={@resources_state}
        conditions_state={@conditions_state}
      />
    </Page.detail_modal>
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

  defp group_form_view(assigns) do
    assigns =
      assign(
        assigns,
        :current_members,
        current_members_for_display(assigns.panel_view, assigns.group, assigns.members_to_remove)
      )

    ~H"""
    <Form.panel_header title={if @panel_view == :new_form, do: "New group", else: "Edit #{@group && @group.name}"}>
      <:leading>
        <Navigation.link
          :if={@panel_view == :edit_form && @group}
          patch={~p"/#{@account}/groups/#{@group.id}"}
          class="flex items-center justify-center w-7 h-7 text-muted hover:text-fg hover:bg-hover"
          title="Back to group"
        >
          <Core.icon name="ri-arrow-left-line" class="w-4 h-4" />
        </Navigation.link>
        <Core.icon :if={@panel_view == :new_form} name="ri-team-line" class="w-5 h-5 text-muted" />
      </:leading>
    </Form.panel_header>
    <.form
      id="group-form"
      for={@form}
      phx-change="validate"
      phx-submit={if @panel_view == :new_form, do: "create", else: "save"}
      class="flex flex-col flex-1 min-h-0 overflow-hidden"
    >
      <div class="flex-1 overflow-y-auto px-6 py-5 space-y-5">
        <Core.flash id="group-success-inline" kind={:success_inline} style="inline" flash={@flash} />
        <Form.input
          field={@form[:name]}
          label="Group Name"
          placeholder="Enter group name"
          autocomplete="off"
          phx-debounce="300"
          data-1p-ignore
          required
        />
        <div>
          <h3 class="flex items-center gap-1.5 text-sm font-medium text-fg mb-2">
            <Core.icon name="ri-user-line" class="w-4 h-4 text-muted" />
            Members ({length(@current_members) + length(@members_to_add)})
          </h3>
          <.member_search_input form={@form} member_search_results={@member_search_results} />
          <div class="grid gap-2 mt-2 lg:grid-cols-3">
            <.member_bucket
              title="Current"
              members={@current_members}
              empty_message="No current members."
              action="remove_member"
              action_title="Remove from current members"
            />
            <.member_bucket
              title="To Add"
              members={@members_to_add}
              empty_message="No pending additions."
              action="remove_member"
              action_title="Remove from pending additions"
            />
            <.member_bucket
              title="To Remove"
              members={@members_to_remove}
              empty_message="No pending removals."
              action="undo_member_removal"
              action_title="Remove from pending removals"
            />
          </div>
        </div>
      </div>
      <Form.panel_footer>
        <Form.panel_footer_button patch={
          if @panel_view == :edit_form && @group,
            do: ~p"/#{@account}/groups/#{@group.id}",
            else: ~p"/#{@account}/groups"
        }>
          Cancel
        </Form.panel_footer_button>
        <Form.panel_footer_button
          type="submit"
          style="primary"
          disabled={
            if @panel_view == :new_form,
              do: not @form.source.valid?,
              else: edit_form_unchanged?(@form, @members_to_add, @members_to_remove)
          }
        >
          {if @panel_view == :new_form, do: "Create Group", else: "Save Changes"}
        </Form.panel_footer_button>
      </Form.panel_footer>
    </.form>
    """
  end

  attr :account, :any, required: true
  attr :group, :any, required: true
  attr :edit_path, :string, required: true
  attr :flash, :map, required: true
  attr :panel, :map, required: true
  attr :members_state, :map, required: true
  attr :resources_state, :map, required: true
  attr :conditions_state, :map, required: true

  defp group_details_view(assigns) do
    assigns =
      assigns
      |> assign(assigns.panel)
      |> assign(assigns.members_state)
      |> assign(assigns.resources_state)

    ~H"""
    <div class="flex flex-col min-h-0 h-full">
      <.group_details_header
        account={@account}
        group={@group}
        edit_path={@edit_path}
        confirm_delete?={@confirm_delete?}
        granting?={@tab_view == :grant_form}
      />

      <div :if={@tab_view == :grant_form} class="flex flex-col flex-1 min-h-0">
        <.group_grant_resource_form
          account={@account}
          resources_state={@resources_state}
          conditions_state={@conditions_state}
        />
      </div>

      <div :if={@tab_view != :grant_form} class="flex-1 overflow-y-auto">
        <Core.flash id="group-success-inline-show" kind={:success_inline} style="inline" flash={@flash} />
        <div class="grid gap-10 px-6 py-6 md:grid-cols-2">
          <.group_members_section
            account={@account}
            group={@group}
            panel_members={@panel_members}
            member_total={@member_total}
            member_pages={@member_pages}
            member_page={@member_page}
            show_member_filter={@show_member_filter}
            add_member_results={@add_member_results}
          />
          <.group_reach_section
            account={@account}
            resources={@resources}
            resource_access_actions_open_id={@resource_access_actions_open_id}
            confirm_remove_resource_access_id={@confirm_remove_resource_access_id}
          />
        </div>
        <.group_details_section group={@group} />
      </div>
    </div>
    """
  end

  attr :account, :any, required: true
  attr :group, :any, required: true
  attr :edit_path, :string, required: true
  attr :confirm_delete?, :boolean, required: true
  attr :granting?, :boolean, required: true

  defp group_details_header(assigns) do
    ~H"""
    <div class="shrink-0 px-6 pt-5 pb-4 border-b border-hair">
      <div class="flex items-start gap-4">
        <Core.provider_icon provider={Core.provider_type_from_group(@group)} size="lg" variant="circle" />
        <div class="min-w-0 flex-1">
          <h2 class="flex items-center gap-2 text-[22px] leading-tight font-bold tracking-tight text-fg">
            <span class="truncate">{@group.name}</span>
            <Core.badge :if={@group.entity_type == :org_unit} size="xs" title="Organizational Unit">
              OU
            </Core.badge>
          </h2>
          <p class="mt-1 text-sm text-muted">{group_source(@group)}</p>
        </div>
        <div class="flex flex-wrap items-center justify-end gap-1.5 shrink-0">
          <Form.button
            navigate={~p"/#{@account}/activity?#{[pivot: ["group:#{@group.id}"]]}"}
            size="sm"
            icon="ri-pulse-line"
          >
            Activity
          </Form.button>
          <Form.button
            :if={not @granting?}
            type="button"
            phx-click="open_grant_resource_form"
            style="primary"
            size="sm"
            icon="ri-shield-check-line"
          >
            Grant access
          </Form.button>
          <Form.button
            :if={editable_group?(@group)}
            patch={@edit_path}
            size="sm"
            icon="ri-pencil-line"
          >
            Edit
          </Form.button>
          <Form.button
            :if={deletable_group?(@group) and not @confirm_delete?}
            type="button"
            phx-click="confirm_delete_group"
            style="danger"
            size="sm"
            icon="ri-delete-bin-line"
          >
            Delete group
          </Form.button>
          <Form.icon_button icon="ri-close-line" title="Close (Esc)" phx-click="close_panel" />
        </div>
      </div>
      <div
        :if={deletable_group?(@group) and @confirm_delete?}
        class="mt-4 px-4 py-3 border border-attn bg-attn-wash"
      >
        <p class="text-sm font-semibold text-attn">Delete this group?</p>
        <p class="mt-1 text-xs text-attn">
          All associated policies will also be deleted and clients will immediately lose access.
        </p>
        <div class="flex items-center gap-1.5 mt-3">
          <Form.button type="button" phx-click="cancel_delete_group" size="xs">Cancel</Form.button>
          <Form.button type="button" phx-click="delete" phx-value-id={@group.id} style="danger" size="xs">
            Delete
          </Form.button>
        </div>
      </div>
    </div>
    """
  end

  attr :account, :any, required: true
  attr :group, :any, required: true
  attr :panel_members, :list, required: true
  attr :member_total, :integer, required: true
  attr :member_pages, :integer, required: true
  attr :member_page, :integer, required: true
  attr :show_member_filter, :string, required: true
  attr :add_member_results, :any, default: nil

  defp group_members_section(assigns) do
    assigns = assign(assigns, :editable?, editable_group?(assigns.group))

    ~H"""
    <section id="group-members" class="min-w-0">
      <div class="flex items-center justify-between gap-3 mb-2.5">
        <.eyebrow icon="ri-user-line">Members · {@member_total}</.eyebrow>
        <form id="filter-members-form" phx-change="filter_show_members" class="relative">
          <Core.icon
            name="ri-search-line"
            class="absolute left-2 top-1/2 -translate-y-1/2 w-3 h-3 text-muted pointer-events-none"
          />
          <input
            type="text"
            value={@show_member_filter}
            placeholder="Filter..."
            phx-debounce="300"
            name="filter"
            autocomplete="off"
            data-1p-ignore
            class="w-36 pl-6 pr-2 py-1 text-xs border border-rule bg-bg text-fg placeholder:text-muted outline-none focus:border-fg"
          />
        </form>
      </div>
      <ul class="border-t border-rule">
        <li
          :for={actor <- @panel_members}
          id={"group-member-#{actor.id}"}
          class="flex items-center justify-between gap-3 py-2 border-b border-hair"
        >
          <div class="flex items-center gap-2.5 min-w-0">
            <Core.icon name={member_icon(actor)} class="w-4 h-4 text-muted shrink-0" />
            <div class="min-w-0">
              <.link navigate={member_path(@account, actor)} class="block text-sm text-fg truncate hover:underline">
                {actor.name}
              </.link>
              <p
                :if={actor.email || actor.type == :service_account}
                class="text-xs text-muted truncate"
              >
                {actor.email || "(Service Account)"}
              </p>
            </div>
          </div>
          <button
            :if={@editable?}
            type="button"
            phx-click="remove_group_member"
            phx-value-actor_id={actor.id}
            class="shrink-0 text-xs text-muted hover:text-attn"
            title={"Remove #{actor.name}"}
          >
            remove
          </button>
        </li>
      </ul>
      <p
        :if={@panel_members == [] && @member_total == 0}
        class="flex items-center gap-2 py-3 text-sm text-muted"
      >
        <Core.icon name="ri-user-line" class="w-4 h-4 text-faint" />
        <%= if has_content?(@show_member_filter) do %>
          No members match your filter.
        <% else %>
          No members in this group.
        <% end %>
      </p>
      <div :if={@member_pages > 1} class="flex items-center justify-between py-2">
        <span class="text-xs text-muted">
          Page {@member_page} of {@member_pages} ({@member_total} members)
        </span>
        <div class="flex items-center gap-1">
          <Form.icon_button
            style="outline"
            icon="ri-arrow-left-s-line"
            title="Previous page"
            phx-click="prev_member_page"
            disabled={@member_page <= 1}
          />
          <Form.icon_button
            style="outline"
            icon="ri-arrow-right-s-line"
            title="Next page"
            phx-click="next_member_page"
            disabled={@member_page >= @member_pages}
          />
        </div>
      </div>
      <div :if={@editable?} class="relative mt-3" phx-click-away="blur_members_to_add">
        <form id="add-member-form" phx-change="search_members_to_add" phx-submit="search_members_to_add">
          <Core.icon
            name="ri-user-add-line"
            class="absolute left-2.5 top-1/2 -translate-y-1/2 w-3.5 h-3.5 text-muted pointer-events-none"
          />
          <input
            type="text"
            name="q"
            placeholder="Add a member..."
            phx-debounce="300"
            autocomplete="off"
            data-1p-ignore
            class="w-full pl-8 pr-3 py-1.5 text-sm border border-rule bg-bg text-fg placeholder:text-muted outline-none focus:border-fg"
          />
        </form>
        <div
          :if={@add_member_results != nil}
          class="absolute z-10 left-0 right-0 mt-1 bg-bg border border-rule shadow-lg max-h-56 overflow-y-auto"
        >
          <button
            :for={actor <- @add_member_results}
            type="button"
            phx-click="add_group_member"
            phx-value-actor_id={actor.id}
            class="flex items-center gap-2 w-full text-left px-3 py-2 border-b border-hair last:border-b-0 hover:bg-hover"
          >
            <Core.icon name={member_icon(actor)} class="w-3.5 h-3.5 text-muted shrink-0" />
            <span class="text-sm text-fg truncate">{actor.name}</span>
            <span :if={actor.email} class="text-xs text-muted truncate">{actor.email}</span>
          </button>
          <p :if={@add_member_results == []} class="px-3 py-3 text-xs text-muted">No one found.</p>
        </div>
      </div>
    </section>
    """
  end

  attr :account, :any, required: true
  attr :resources, :list, required: true
  attr :resource_access_actions_open_id, :any, default: nil
  attr :confirm_remove_resource_access_id, :any, default: nil

  defp group_reach_section(assigns) do
    ~H"""
    <section id="group-reach" class="min-w-0">
      <.eyebrow icon="ri-route-line">Can reach</.eyebrow>
      <ul class="border-t border-rule">
        <li :for={row <- @resources} class="border-b border-hair">
          <div
            :if={@confirm_remove_resource_access_id == row.resource.id}
            class="flex items-center justify-between gap-2 px-2 py-2.5 bg-attn-wash"
          >
            <span class="text-xs text-fg truncate">
              Remove access to <span class="font-medium">{row.resource.name}</span>?
              <span class="block text-muted">All group members will immediately lose access.</span>
            </span>
            <div class="flex items-center gap-1.5 shrink-0">
              <Form.button type="button" phx-click="cancel_remove_resource_access" size="xs">
                Cancel
              </Form.button>
              <Form.button
                type="button"
                phx-click="remove_resource_access"
                phx-value-resource_id={row.resource.id}
                style="danger"
                size="xs"
              >
                Remove
              </Form.button>
            </div>
          </div>
          <div
            :if={@confirm_remove_resource_access_id != row.resource.id}
            class={[
              "flex items-start justify-between gap-3 py-2",
              @resource_access_actions_open_id == row.resource.id && "relative z-20"
            ]}
          >
            <div class={["min-w-0", row.policy_is_disabled && "opacity-50"]}>
              <div class="flex items-center gap-2">
                <.link
                  navigate={~p"/#{@account}/policies/#{row.policy_id}"}
                  class="text-sm text-fg truncate hover:underline"
                >
                  {row.resource.name}
                </.link>
                <Core.badge :if={row.policy_is_disabled} size="xs">disabled</Core.badge>
              </div>
              <p class="text-xs text-muted truncate">
                {conditions_summary(row.policy) || row.resource.address}
              </p>
            </div>
            <div class="flex items-center gap-1 shrink-0">
              <Actors.Components.route_chip resource={row.resource} site_name={row.site_name} />
              <Core.actions_dropdown
                open={@resource_access_actions_open_id == row.resource.id}
                close_event="close_resource_access_actions"
                button_class="flex items-center justify-center w-6 h-6 text-muted hover:text-fg hover:bg-hover"
                icon_class="w-3.5 h-3.5"
                phx-click="toggle_resource_access_actions"
                phx-value-resource_id={row.resource.id}
                title="More actions"
              >
                <Navigation.link
                  navigate={~p"/#{@account}/resources/#{row.resource.id}"}
                  class="flex items-center gap-2 w-full px-3 py-1.5 text-xs text-fg hover:bg-hover"
                >
                  <Core.icon name="ri-server-line" class="w-3.5 h-3.5 shrink-0" /> Go to Resource
                </Navigation.link>
                <button
                  :if={!row.policy_is_disabled}
                  type="button"
                  phx-click="disable_resource_access"
                  phx-value-resource_id={row.resource.id}
                  class="flex items-center gap-2 w-full px-3 py-1.5 text-xs text-fg hover:bg-hover"
                >
                  <Core.icon name="ri-pause-circle-line" class="w-3.5 h-3.5 shrink-0" /> Disable
                </button>
                <button
                  :if={row.policy_is_disabled}
                  type="button"
                  phx-click="enable_resource_access"
                  phx-value-resource_id={row.resource.id}
                  class="flex items-center gap-2 w-full px-3 py-1.5 text-xs text-fg hover:bg-hover"
                >
                  <Core.icon name="ri-play-circle-line" class="w-3.5 h-3.5 shrink-0" /> Enable
                </button>
                <button
                  type="button"
                  phx-click="confirm_remove_resource_access"
                  phx-value-resource_id={row.resource.id}
                  class="flex items-center gap-2 w-full px-3 py-1.5 text-xs text-attn hover:bg-attn-wash"
                >
                  <Core.icon name="ri-delete-bin-line" class="w-3.5 h-3.5 shrink-0" /> Remove access
                </button>
              </Core.actions_dropdown>
            </div>
          </div>
        </li>
      </ul>
      <div :if={@resources == []} class="flex items-start gap-2 py-3 text-sm text-muted">
        <Core.icon name="ri-route-line" class="w-4 h-4 text-faint mt-0.5" />
        <div>
          <p>No resource access</p>
          <p class="text-xs">Grant access to let this group reach a resource.</p>
        </div>
      </div>
    </section>
    """
  end

  attr :group, :any, required: true

  defp group_details_section(assigns) do
    ~H"""
    <details id="group-details" class="group/more border-t border-hair">
      <summary class="flex items-center gap-2 px-6 py-3 cursor-pointer list-none hover:bg-hover">
        <Core.icon name="ri-information-line" class="w-4 h-4 text-muted" />
        <span class="text-[11px] font-semibold tracking-[.12em] uppercase text-muted">Details</span>
        <Core.icon name="ri-arrow-down-s-line" class="w-4 h-4 text-muted group-open/more:hidden" />
        <Core.icon name="ri-arrow-up-s-line" class="w-4 h-4 text-muted hidden group-open/more:block" />
      </summary>
      <dl class="grid gap-x-8 gap-y-3 px-6 pb-6 sm:grid-cols-2 lg:grid-cols-3">
        <.detail_field label="ID" mono>{@group.id}</.detail_field>
        <.detail_field label="Name">{@group.name}</.detail_field>
        <.detail_field label="Directory">{directory_display_name(@group.directory)}</.detail_field>
        <.detail_field :if={@group.entity_type == :org_unit} label="Type">Org Unit</.detail_field>
        <.detail_field label="Created">
          <Core.relative_datetime datetime={@group.inserted_at} />
        </.detail_field>
        <.detail_field label="Updated">
          <Core.relative_datetime datetime={@group.updated_at} />
        </.detail_field>
        <.detail_field
          :if={Ecto.assoc_loaded?(@group.sync_state) && @group.sync_state && @group.sync_state.synced_at}
          label="Last synced"
        >
          <Core.relative_datetime datetime={@group.sync_state.synced_at} />
        </.detail_field>
        <.detail_field :if={@group.idp_id && get_idp_id(@group.idp_id)} label="IDP ID" mono>
          {get_idp_id(@group.idp_id)}
        </.detail_field>
      </dl>
    </details>
    """
  end

  attr :account, :any, required: true
  attr :resources_state, :map, required: true
  attr :conditions_state, :map, required: true

  defp group_grant_resource_form(assigns) do
    assigns =
      assigns
      |> assign(assigns.resources_state)
      |> assign(assigns.conditions_state)

    filtered_available =
      assigns.available_resources
      |> Enum.reject(&(&1.id in assigns.grant_selected_resource_ids))
      |> Enum.filter(&resource_matches?(&1, assigns.grant_resource_search))

    selected_resources =
      Enum.filter(assigns.available_resources, &(&1.id in assigns.grant_selected_resource_ids))

    assigns =
      assigns
      |> assign(:filtered_available, filtered_available)
      |> assign(:selected_resources, selected_resources)
      |> assign(:allowed_conditions, allowed_conditions(selected_resources))
      |> assign(:card_state, %{
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
    <div class="flex items-center gap-2 px-6 py-2.5 border-b border-hair shrink-0">
      <Form.icon_button
        icon="ri-arrow-left-s-line"
        title="Back to the group"
        phx-click="close_grant_resource_form"
        size="sm"
      />
      <span class="text-[11px] font-semibold tracking-[.12em] uppercase text-muted">Grant access</span>
    </div>
    <.form
      for={@grant_resource_form}
      phx-submit="submit_grant_resource"
      id="grant-resource-form"
      class="flex-1 flex flex-col min-h-0 overflow-hidden"
    >
      <div class="flex-1 overflow-y-auto px-6 py-5 space-y-5">
        <div>
          <label class="block text-xs font-medium text-muted mb-2">
            Resources <span class="text-attn">*</span>
          </label>
          <div class="flex gap-2 h-52">
            <div class="flex-1 flex flex-col min-w-0 border border-hair">
              <div class="flex items-center justify-between px-2.5 py-1.5 border-b border-hair shrink-0">
                <span class="text-[11px] font-semibold uppercase tracking-[.12em] text-muted">Available</span>
                <span class="text-[11px] text-muted tabular-nums">{length(@filtered_available)}</span>
              </div>
              <div class="px-2 pt-1.5 shrink-0 relative">
                <Core.icon
                  name="ri-search-line"
                  class="absolute left-4 top-1/2 translate-y-[-25%] w-3 h-3 text-muted pointer-events-none"
                />
                <input
                  type="text"
                  placeholder="Search…"
                  value={@grant_resource_search}
                  phx-keyup="search_grant_resources"
                  phx-debounce="200"
                  autocomplete="off"
                  data-1p-ignore
                  class="w-full pl-6 pr-2 py-1 text-xs border border-rule bg-bg text-fg placeholder:text-muted outline-none focus:border-fg"
                />
              </div>
              <ul class="flex-1 overflow-y-auto px-1 py-1.5">
                <li :for={resource <- @filtered_available}>
                  <button
                    type="button"
                    phx-click="toggle_grant_resource"
                    phx-value-resource_id={resource.id}
                    class="flex items-center gap-2 px-2 py-1.5 w-full text-left hover:bg-hover"
                  >
                    <div class="flex-1 min-w-0">
                      <p class="text-xs text-fg truncate">{resource.name}</p>
                      <p class="text-[11px] text-muted font-mono truncate">{resource.address}</p>
                    </div>
                  </button>
                </li>
                <li
                  :if={@available_resources == []}
                  class="flex items-center justify-center h-16 text-xs text-muted"
                >
                  All resources already have access.
                </li>
                <li
                  :if={@available_resources != [] && @filtered_available == []}
                  class="flex items-center justify-center h-12 text-xs text-muted"
                >
                  No resources match.
                </li>
              </ul>
            </div>
            <div class="flex-1 flex flex-col min-w-0 border border-hair">
              <div class="flex items-center justify-between px-2.5 py-1.5 border-b border-hair shrink-0">
                <span class="text-[11px] font-semibold uppercase tracking-[.12em] text-muted">Selected</span>
                <span class="text-[11px] text-muted tabular-nums">{length(@grant_selected_resource_ids)}</span>
              </div>
              <ul class="flex-1 overflow-y-auto px-1 py-1.5">
                <li :for={resource <- @selected_resources}>
                  <button
                    type="button"
                    phx-click="toggle_grant_resource"
                    phx-value-resource_id={resource.id}
                    class="flex items-center gap-2 px-2 py-1.5 w-full text-left hover:bg-hover group"
                  >
                    <div class="flex-1 min-w-0">
                      <p class="text-xs text-fg truncate">{resource.name}</p>
                      <p class="text-[11px] text-muted font-mono truncate">{resource.address}</p>
                    </div>
                    <Core.icon
                      name="ri-close-line"
                      class="w-3.5 h-3.5 text-muted opacity-0 group-hover:opacity-100 shrink-0"
                    />
                  </button>
                </li>
                <li
                  :if={@selected_resources == []}
                  class="flex items-center justify-center h-16 text-xs text-muted"
                >
                  No resources selected.
                </li>
              </ul>
            </div>
          </div>
        </div>
        <div class="border-t border-hair pt-4">
          <Policies.Components.flow_log_uploads_toggle
            form={@grant_resource_form}
            internet_resource?={Enum.any?(@selected_resources, &(&1.type == :internet))}
          />
        </div>
        <Policies.PostureComponents.policy_restrictions
          id="group-grant-postures"
          account={@account}
          state={@postures}
        >
          <div class="border-t border-hair pt-4">
            <div class="flex items-center justify-between mb-3">
              <h4 class="text-[11px] font-semibold tracking-[.12em] uppercase text-muted">
                Conditions
                <span class="ml-1 font-normal normal-case tracking-normal">(optional)</span>
              </h4>
              <div :if={@allowed_conditions -- @active_conditions != []} class="relative">
                <Form.button
                  type="button"
                  phx-click="toggle_conditions_dropdown"
                  size="xs"
                  icon="ri-add-line"
                >
                  Add condition
                </Form.button>
                <div :if={@conditions_dropdown_open?}>
                  <div class="fixed inset-0 z-10" phx-click="toggle_conditions_dropdown"></div>
                  <div class="absolute right-0 top-full mt-1 z-20 min-w-44 border border-rule bg-bg shadow-lg py-1">
                    <button
                      :for={type <- @allowed_conditions -- @active_conditions}
                      type="button"
                      phx-click="add_condition"
                      phx-value-type={type}
                      class="w-full text-left px-3 py-1.5 text-xs text-fg hover:bg-hover"
                    >
                      {Policies.Components.condition_type_label(type)}
                    </button>
                  </div>
                </div>
              </div>
            </div>
            <p
              :if={@active_conditions == []}
              class="text-xs text-muted text-center py-4 border border-dashed border-hair"
            >
              No conditions - access is unrestricted
            </p>
            <div class="space-y-2">
              <Policies.Components.grant_condition_card
                :for={type <- @active_conditions}
                type={type}
                providers={@providers}
                conditions_state={@card_state}
              />
            </div>
          </div>
        </Policies.PostureComponents.policy_restrictions>
      </div>
      <div
        :if={@grant_resource_form && @grant_resource_form.errors != []}
        class="px-6 py-2 text-xs text-attn"
      >
        <p :for={{_field, {msg, _}} <- @grant_resource_form.errors}>{msg}</p>
      </div>
      <Form.panel_footer>
        <Form.panel_footer_button type="button" phx-click="close_grant_resource_form">
          Cancel
        </Form.panel_footer_button>
        <Form.panel_footer_button
          type="submit"
          style="primary"
          disabled={@grant_selected_resource_ids == [] or PortalWeb.Policies.Postures.blocked?(@postures)}
        >
          Grant access
        </Form.panel_footer_button>
      </Form.panel_footer>
    </.form>
    """
  end

  attr :form, :any, required: true
  attr :member_search_results, :any, default: nil

  defp member_search_input(assigns) do
    ~H"""
    <div class="relative" phx-click-away="blur_search">
      <Core.icon
        name="ri-search-line"
        class="absolute left-2.5 top-1/2 -translate-y-1/2 w-3 h-3 text-muted pointer-events-none"
      />
      <input
        type="text"
        name={@form[:member_search].name}
        value={@form[:member_search].value}
        placeholder="Search to add members..."
        phx-debounce="300"
        phx-focus="focus_search"
        autocomplete="off"
        data-1p-ignore
        class="w-full pl-7 pr-3 py-1.5 text-sm border border-rule bg-bg text-fg placeholder:text-muted outline-none focus:border-fg"
      />
      <div
        :if={@member_search_results != nil}
        class="absolute z-10 left-0 right-0 mt-1 bg-bg border border-rule shadow-lg max-h-48 overflow-y-auto"
      >
        <button
          :for={actor <- @member_search_results}
          type="button"
          phx-click="add_member"
          phx-value-actor_id={actor.id}
          class="flex items-center gap-2 w-full text-left px-3 py-2 border-b border-hair last:border-b-0 hover:bg-hover"
        >
          <Core.icon name={member_icon(actor)} class="w-3.5 h-3.5 text-muted shrink-0" />
          <span class="text-xs font-medium text-fg">{actor.name}</span>
          <span :if={actor.email} class="text-xs text-muted truncate">{actor.email}</span>
        </button>
        <div :if={@member_search_results == []} class="px-3 py-4 text-center text-xs text-muted">
          No members found
        </div>
      </div>
    </div>
    """
  end

  attr :members, :list, required: true
  attr :title, :string, required: true
  attr :empty_message, :string, required: true
  attr :action, :string, required: true
  attr :action_title, :string, required: true

  defp member_bucket(assigns) do
    ~H"""
    <section class="min-w-0 border border-hair">
      <div class="flex items-center justify-between px-2.5 py-1.5 border-b border-hair">
        <h4 class="text-[11px] font-semibold uppercase tracking-[.12em] text-muted">{@title}</h4>
        <span class="text-[11px] text-muted tabular-nums">{length(@members)}</span>
      </div>
      <ul :if={@members != []} class="h-48 overflow-y-auto px-1 py-1">
        <li :for={actor <- @members} class="flex items-center gap-2 px-2 py-1.5 hover:bg-hover">
          <Core.icon name={member_icon(actor)} class="w-3.5 h-3.5 text-muted shrink-0" />
          <div class="flex-1 min-w-0">
            <p class="text-xs font-medium text-fg truncate">{actor.name}</p>
            <p :if={actor.email} class="text-xs text-muted truncate">{actor.email}</p>
          </div>
          <button
            type="button"
            phx-click={@action}
            phx-value-actor_id={actor.id}
            class="shrink-0 text-muted hover:text-attn"
            title={@action_title}
          >
            <Core.icon name="ri-close-line" class="w-4 h-4" />
          </button>
        </li>
      </ul>
      <div :if={@members == []} class="flex items-center justify-center h-16">
        <p class="text-xs text-muted">{@empty_message}</p>
      </div>
    </section>
    """
  end

  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp eyebrow(assigns) do
    ~H"""
    <h3 class="flex items-center gap-1.5 mb-2.5 text-[11px] font-semibold tracking-[.12em] uppercase text-muted">
      <Core.icon name={@icon} class="w-3.5 h-3.5" /> {render_slot(@inner_block)}
    </h3>
    """
  end

  attr :label, :string, required: true
  attr :mono, :boolean, default: false
  slot :inner_block, required: true

  defp detail_field(assigns) do
    ~H"""
    <div class="min-w-0">
      <dt class="text-[11px] font-semibold tracking-[.12em] uppercase text-muted">{@label}</dt>
      <dd class={["text-sm text-fg mt-0.5 break-all", @mono && "font-mono text-xs"]}>
        {render_slot(@inner_block)}
      </dd>
    </div>
    """
  end

  defp group_source(%{type: :managed}), do: "Built in"

  defp group_source(group) do
    cond do
      name = directory_name(group) -> "Synced from #{name}"
      not is_nil(group.idp_id) -> "Synced"
      true -> "Manual"
    end
  end

  defp directory_name(%{directory: directory}) when is_map(directory),
    do: directory_name_from(directory)

  defp directory_name(_group), do: nil

  defp directory_name_from(%{google_directory: %{name: name}}) when is_binary(name), do: name
  defp directory_name_from(%{entra_directory: %{name: name}}) when is_binary(name), do: name
  defp directory_name_from(%{okta_directory: %{name: name}}) when is_binary(name), do: name
  defp directory_name_from(_directory), do: nil

  defp conditions_summary(policy) do
    labels =
      Enum.map(policy.conditions, &Policies.Components.condition_short_label(&1.property)) ++
        attestation_label(policy) ++ posture_label(policy)

    if labels == [] do
      nil
    else
      "Conditions: " <> Enum.join(Enum.uniq(labels), " · ")
    end
  end

  defp attestation_label(%{require_attestation: true}), do: ["Attested device"]
  defp attestation_label(_policy), do: []

  defp posture_label(%{postures: nil}), do: []
  defp posture_label(_policy), do: ["Device posture"]

  defp resource_matches?(_resource, ""), do: true

  defp resource_matches?(resource, search) do
    search = String.downcase(search)

    String.contains?(String.downcase(resource.name), search) or
      String.contains?(String.downcase(resource.address || ""), search)
  end

  defp allowed_conditions([]), do: []

  defp allowed_conditions(resources) do
    resources
    |> Enum.map(&Policies.Components.available_conditions/1)
    |> Enum.reduce(&Enum.filter(&2, fn condition -> condition in &1 end))
  end

  defp member_icon(%{type: :service_account}), do: "ri-robot-3-line"
  defp member_icon(%{type: :account_admin_user}), do: "ri-shield-user-line"
  defp member_icon(_actor), do: "ri-user-line"

  defp member_path(account, %{type: :service_account} = actor),
    do: ~p"/#{account}/service_accounts/#{actor.id}"

  defp member_path(account, actor), do: ~p"/#{account}/actors/#{actor.id}"

  defp editable_group?(%{type: :managed, name: "Everyone"}), do: false
  defp editable_group?(%{idp_id: nil}), do: true
  defp editable_group?(_group), do: false

  defp deletable_group?(%{name: "Everyone"}), do: false
  defp deletable_group?(_group), do: true

  defp directory_display_name(directory), do: directory_name_from(directory) || "Firezone"

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

  defp current_members_for_display(:edit_form, %{actors: actors}, members_to_remove) do
    remove_ids = MapSet.new(members_to_remove, & &1.id)
    Enum.reject(actors, &MapSet.member?(remove_ids, &1.id))
  end

  defp current_members_for_display(_view, _group, _members_to_remove), do: []
end
