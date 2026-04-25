defmodule PortalWeb.Policies.Components do
  use PortalWeb, :component_library
  alias Portal.Policies.Condition
  alias PortalWeb.Policies.Database

  @days_of_week [
    {"M", "Monday"},
    {"T", "Tuesday"},
    {"W", "Wednesday"},
    {"R", "Thursday"},
    {"F", "Friday"},
    {"S", "Saturday"},
    {"U", "Sunday"}
  ]

  @all_conditions [
    :remote_ip_location_region,
    :remote_ip,
    :auth_provider_id,
    :client_verified,
    :current_utc_datetime
  ]

  # current_utc_datetime is a condition evaluated at the time of the request,
  # so we don't need to include it in the list of conditions that can be set
  # for internet resources, otherwise it would be blocking all the requests.
  @conditions_by_resource_type %{
    internet: @all_conditions -- [:current_utc_datetime],
    dns: @all_conditions,
    ip: @all_conditions,
    cidr: @all_conditions,
    static_device_pool: @all_conditions
  }

  attr(:policy, :map, required: true)

  def policy_name(%{policy: %{group: nil}} = assigns) do
    ~H"""
    <span class="text-amber-600">(Group deleted)</span> → {@policy.resource.name}
    """
  end

  def policy_name(assigns) do
    ~H"{@policy.group.name} → {@policy.resource.name}"
  end

  def maybe_drop_unsupported_conditions(attrs, socket) do
    if Portal.Account.policy_conditions_enabled?(socket.assigns.account) do
      attrs
    else
      Map.delete(attrs, "conditions")
    end
  end

  def map_condition_params(attrs, opts) do
    Map.update(attrs, "conditions", %{}, fn conditions ->
      for {property, condition_attrs} <- conditions,
          maybe_filter(condition_attrs, opts),
          condition_attrs = map_condition_values(condition_attrs),
          into: %{} do
        {property, condition_attrs}
      end
    end)
  end

  defp maybe_filter(%{"values" => values}, empty_values: :drop) when is_list(values) do
    not (values
         |> List.wrap()
         |> Enum.reject(fn value -> value in [nil, ""] end)
         |> Enum.empty?())
  end

  defp maybe_filter(%{"values" => values}, empty_values: :drop) when is_map(values) do
    not (values
         |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
         |> Enum.empty?())
  end

  defp maybe_filter(%{}, empty_values: :drop) do
    false
  end

  defp maybe_filter(_condition_attrs, _opts) do
    true
  end

  defp map_condition_values(
         %{
           "operator" => "is_in_day_of_week_time_ranges",
           "timezone" => timezone
         } = condition_attrs
       ) do
    Map.update(condition_attrs, "values", [], fn values ->
      day_ranges =
        values
        |> Enum.sort_by(fn {idx, _} -> String.to_integer(idx) end)
        |> Enum.flat_map(fn
          {_idx, %{"on" => on, "off" => off, "days" => days}}
          when is_binary(on) and on != "" and is_binary(off) and off != "" ->
            days
            |> List.wrap()
            |> Enum.filter(&(&1 in ["M", "T", "W", "R", "F", "S", "U"]))
            |> Enum.map(&{&1, "#{on}-#{off}"})

          _ ->
            []
        end)

      day_ranges
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.sort_by(fn {day, _} -> day_of_week_index(day) end)
      |> Enum.map(fn {day, ranges} -> "#{day}/#{Enum.join(ranges, ",")}/#{timezone}" end)
    end)
  end

  defp map_condition_values(condition_attrs) do
    condition_attrs
  end

  defp condition_values_empty?(%{data: %{values: values}}) when values != [] do
    false
  end

  defp condition_values_empty?(%{
         params: %{
           "operator" => "is_in_day_of_week_time_ranges",
           "values" => values
         }
       }) do
    values
    |> Enum.reject(fn value ->
      case String.split(value, "/") do
        [_, ranges, _] -> ranges == ""
        _ -> true
      end
    end)
    |> Enum.empty?()
  end

  defp condition_values_empty?(%{
         params: %{"values" => values}
       }) do
    values
    |> List.wrap()
    |> Enum.reject(fn value -> value in [nil, ""] end)
    |> Enum.empty?()
  end

  defp condition_values_empty?(%{}) do
    true
  end

  attr :account, :any, required: true
  attr :policy, :any, default: nil
  attr :providers, :list, default: []
  attr :subject, :any, required: true
  attr :panel, :map, required: true
  attr :conditions_state, :map, required: true
  attr :confirm_state, :map, required: true

  def policy_panel(assigns) do
    cs = assigns.conditions_state

    assigns =
      assign(assigns, :form_conditions_state, %{
        timezone: cs.panel_timezone,
        location_search: cs.panel_location_search,
        location_operator: cs.panel_location_operator,
        location_values: cs.panel_location_values,
        ip_range_operator: cs.panel_ip_range_operator,
        ip_range_values: cs.panel_ip_range_values,
        ip_range_input: cs.panel_ip_range_input,
        auth_provider_operator: cs.panel_auth_provider_operator,
        auth_provider_values: cs.panel_auth_provider_values,
        tod_values: cs.panel_tod_values,
        tod_adding: cs.panel_tod_adding,
        tod_pending: cs.panel_tod_pending,
        tod_pending_error: cs.panel_tod_pending_error
      })

    ~H"""
    <div
      id="policy-panel"
      class={[
        "absolute inset-y-0 right-0 z-10 flex flex-col w-full lg:w-3/4 xl:w-2/3",
        "bg-[var(--surface-overlay)] border-l border-[var(--border-strong)]",
        "shadow-[-4px_0px_20px_rgba(0,0,0,0.07)]",
        "transition-transform duration-200 ease-in-out",
        if(@policy || @panel.panel_view in [:edit_form, :new_form],
          do: "translate-x-0",
          else: "translate-x-full"
        )
      ]}
      phx-window-keydown="handle_keydown"
      phx-key="Escape"
    >
      <.policy_form_view
        :if={@panel.panel_view == :new_form}
        account={@account}
        subject={@subject}
        providers={@providers}
        panel_form={@panel.panel_form}
        panel_selected_resource={@panel.panel_selected_resource}
        panel_active_conditions={@conditions_state.panel_active_conditions}
        panel_conditions_dropdown_open={@conditions_state.panel_conditions_dropdown_open}
        conditions_state={@form_conditions_state}
        mode={:new}
      />

      <.policy_form_view
        :if={@panel.panel_view == :edit_form}
        account={@account}
        subject={@subject}
        providers={@providers}
        panel_form={@panel.panel_form}
        panel_selected_resource={@panel.panel_selected_resource}
        panel_active_conditions={@conditions_state.panel_active_conditions}
        panel_conditions_dropdown_open={@conditions_state.panel_conditions_dropdown_open}
        conditions_state={@form_conditions_state}
        mode={:edit}
      />

      <.policy_details_view
        :if={@policy && @panel.panel_view == :list}
        account={@account}
        policy={@policy}
        providers={@providers}
        confirm_disable_policy={@confirm_state.confirm_disable_policy}
        confirm_delete_policy={@confirm_state.confirm_delete_policy}
      />
    </div>
    """
  end

  attr :account, :any, required: true
  attr :subject, :any, required: true
  attr :providers, :list, default: []
  attr :panel_form, :any, default: nil
  attr :panel_selected_resource, :any, default: nil
  attr :panel_active_conditions, :list, default: []
  attr :panel_conditions_dropdown_open, :boolean, default: false
  attr :conditions_state, :map, required: true
  attr :mode, :atom, required: true

  def policy_form_view(assigns) do
    ~H"""
    <div class="flex flex-col h-full overflow-hidden">
      <.policy_form_header mode={@mode} />
      <.form
        for={@panel_form}
        phx-submit="submit_policy_form"
        phx-change="change_policy_form"
        class="flex flex-col flex-1 min-h-0 overflow-hidden"
      >
        <.policy_form_body
          mode={@mode}
          subject={@subject}
          providers={@providers}
          panel_form={@panel_form}
          panel_selected_resource={@panel_selected_resource}
          panel_active_conditions={@panel_active_conditions}
          panel_conditions_dropdown_open={@panel_conditions_dropdown_open}
          conditions_state={@conditions_state}
        />
        <.policy_form_actions mode={@mode} />
      </.form>
    </div>
    """
  end

  attr :mode, :atom, required: true

  def policy_form_header(assigns) do
    ~H"""
    <div class="shrink-0 px-5 pt-4 pb-3 border-b border-[var(--border)] bg-[var(--surface-overlay)]">
      <div class="flex items-center justify-between gap-3">
        <h2 class="text-sm font-semibold text-[var(--text-primary)]">
          {if @mode == :new, do: "Add Policy", else: "Edit Policy"}
        </h2>
        <button
          phx-click="cancel_policy_form"
          class="flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
          title="Close (Esc)"
        >
          <.icon name="ri-close-line" class="w-4 h-4" />
        </button>
      </div>
    </div>
    """
  end

  attr :mode, :atom, required: true
  attr :subject, :any, required: true
  attr :providers, :list, default: []
  attr :panel_form, :any, default: nil
  attr :panel_selected_resource, :any, default: nil
  attr :panel_active_conditions, :list, default: []
  attr :panel_conditions_dropdown_open, :boolean, default: false
  attr :conditions_state, :map, required: true

  def policy_form_body(assigns) do
    ~H"""
    <div class="flex-1 overflow-y-auto px-5 py-4 space-y-4">
      <.policy_form_error panel_form={@panel_form} />
      <.policy_fields mode={@mode} panel_form={@panel_form} subject={@subject} />
      <.policy_conditions_section
        mode={@mode}
        panel_selected_resource={@panel_selected_resource}
        panel_active_conditions={@panel_active_conditions}
        panel_conditions_dropdown_open={@panel_conditions_dropdown_open}
        providers={@providers}
        conditions_state={@conditions_state}
      />
    </div>
    """
  end

  attr :panel_form, :any, default: nil

  def policy_form_error(assigns) do
    ~H"""
    <div
      :if={@panel_form.errors[:base]}
      class="flex items-center gap-2 px-3 py-2.5 rounded-lg border border-[var(--status-error)]/20 bg-[var(--status-error-bg)]"
    >
      <.icon name="ri-alert-line" class="w-4 h-4 shrink-0 text-[var(--status-error)]" />
      <p class="text-xs text-[var(--status-error)]">
        {translate_error(@panel_form.errors[:base])}
      </p>
    </div>
    """
  end

  attr :mode, :atom, required: true
  attr :panel_form, :any, default: nil
  attr :subject, :any, required: true

  def policy_fields(assigns) do
    ~H"""
    <fieldset class="flex flex-col gap-4">
      <.policy_group_field mode={@mode} panel_form={@panel_form} subject={@subject} />
      <.policy_resource_field mode={@mode} panel_form={@panel_form} subject={@subject} />
      <.policy_description_field panel_form={@panel_form} />
    </fieldset>
    """
  end

  attr :mode, :atom, required: true
  attr :panel_form, :any, default: nil
  attr :subject, :any, required: true

  def policy_group_field(assigns) do
    ~H"""
    <.live_component
      module={PortalWeb.Components.FormComponents.SelectWithGroups}
      id={if @mode == :new, do: "panel_new_policy_group_id", else: "panel_policy_group_id"}
      label="Group"
      placeholder="Select Group"
      field={@panel_form[:group_id]}
      fetch_option_callback={&Database.fetch_group_option(&1, @subject)}
      list_options_callback={&Database.list_group_options(&1, @subject)}
      value={@panel_form[:group_id].value}
      required
    >
      <:options_group :let={options_group}>{options_group}</:options_group>
      <:option :let={group}>
        <div class="flex items-center gap-2">
          <.provider_icon type={provider_type_from_group(group)} class="w-4 h-4 shrink-0" />
          <span>{group.name}</span>
        </div>
      </:option>
      <:no_options :let={name}>
        <.error data-validation-error-for={name}>No groups available.</.error>
      </:no_options>
      <:no_search_results>No groups found.</:no_search_results>
    </.live_component>
    """
  end

  attr :mode, :atom, required: true
  attr :panel_form, :any, default: nil
  attr :subject, :any, required: true

  def policy_resource_field(assigns) do
    ~H"""
    <.live_component
      module={PortalWeb.Components.FormComponents.SelectWithGroups}
      id={if @mode == :new, do: "panel_new_policy_resource_id", else: "panel_policy_resource_id"}
      label="Resource"
      placeholder="Select Resource"
      field={@panel_form[:resource_id]}
      fetch_option_callback={&PortalWeb.Resources.Components.fetch_resource_option(&1, @subject)}
      list_options_callback={&PortalWeb.Resources.Components.list_resource_options(&1, @subject)}
      on_change={&PortalWeb.Policies.on_panel_resource_change/1}
      value={@panel_form[:resource_id].value}
      required
    >
      <:options_group :let={group}>{group}</:options_group>
      <:option :let={resource}>
        <%= if resource.type == :internet do %>
          Internet
        <% else %>
          {resource.name}
          <span :if={resource.site_id} class="text-[var(--text-tertiary)]">
            ({resource.site.name})
          </span>
        <% end %>
      </:option>
      <:no_options :let={name}>
        <.error data-validation-error-for={name}>No resources available.</.error>
      </:no_options>
      <:no_search_results>No resources found.</:no_search_results>
    </.live_component>
    """
  end

  attr :panel_form, :any, default: nil

  def policy_description_field(assigns) do
    ~H"""
    <.input
      field={@panel_form[:description]}
      label="Description"
      type="textarea"
      placeholder="Enter an optional reason for creating this policy here."
      phx-debounce="300"
    />
    """
  end

  attr :mode, :atom, required: true
  attr :panel_selected_resource, :any, default: nil
  attr :panel_active_conditions, :list, default: []
  attr :panel_conditions_dropdown_open, :boolean, default: false
  attr :providers, :list, default: []
  attr :conditions_state, :map, required: true

  def policy_conditions_section(assigns) do
    ~H"""
    <div
      :if={@mode == :new or not is_nil(@panel_selected_resource)}
      class="border-t border-[var(--border)] pt-4"
    >
      <.policy_conditions_header
        panel_selected_resource={@panel_selected_resource}
        panel_active_conditions={@panel_active_conditions}
        panel_conditions_dropdown_open={@panel_conditions_dropdown_open}
      />
      <%= if is_nil(@panel_selected_resource) do %>
        <.policy_conditions_placeholder />
      <% else %>
        <.policy_conditions_cards
          panel_active_conditions={@panel_active_conditions}
          providers={@providers}
          conditions_state={@conditions_state}
        />
      <% end %>
    </div>
    """
  end

  attr :panel_selected_resource, :any, default: nil
  attr :panel_active_conditions, :list, default: []
  attr :panel_conditions_dropdown_open, :boolean, default: false

  def policy_conditions_header(assigns) do
    ~H"""
    <div class="flex items-center justify-between mb-3">
      <h4 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
        Conditions
        <span class="ml-1 font-normal normal-case tracking-normal text-[var(--text-muted)]">
          (optional)
        </span>
      </h4>
      <.policy_conditions_dropdown
        :if={
          not is_nil(@panel_selected_resource) and
            available_conditions(@panel_selected_resource) -- @panel_active_conditions != []
        }
        panel_selected_resource={@panel_selected_resource}
        panel_active_conditions={@panel_active_conditions}
        panel_conditions_dropdown_open={@panel_conditions_dropdown_open}
      />
    </div>
    """
  end

  def policy_conditions_placeholder(assigns) do
    ~H"""
    <p class="text-xs text-[var(--text-muted)] text-center py-4 rounded-lg border border-dashed border-[var(--border)]">
      Select a resource above to configure conditions
    </p>
    """
  end

  attr :panel_active_conditions, :list, default: []
  attr :providers, :list, default: []
  attr :conditions_state, :map, required: true

  def policy_conditions_cards(assigns) do
    ~H"""
    <p
      :if={@panel_active_conditions == []}
      class="text-xs text-[var(--text-muted)] text-center py-4 rounded-lg border border-dashed border-[var(--border)]"
    >
      No conditions — access is unrestricted
    </p>
    <div :if={@panel_active_conditions != []} class="space-y-2">
      <.grant_condition_card
        :for={type <- @panel_active_conditions}
        type={type}
        providers={@providers}
        conditions_state={@conditions_state}
      />
    </div>
    """
  end

  attr :panel_selected_resource, :any, required: true
  attr :panel_active_conditions, :list, default: []
  attr :panel_conditions_dropdown_open, :boolean, default: false

  def policy_conditions_dropdown(assigns) do
    ~H"""
    <div class="relative">
      <button
        type="button"
        phx-click="toggle_conditions_dropdown"
        class="flex items-center gap-1 px-2 py-1 rounded text-[10px] border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
      >
        <.icon name="ri-add-line" class="w-2.5 h-2.5" /> Add condition
      </button>
      <div :if={@panel_conditions_dropdown_open}>
        <div class="fixed inset-0 z-10" phx-click="toggle_conditions_dropdown"></div>
        <div class="absolute right-0 top-full mt-1 z-20 min-w-44 rounded-lg border border-[var(--border-strong)] bg-[var(--surface-overlay)] shadow-lg py-1 overflow-hidden">
          <button
            :for={type <- available_conditions(@panel_selected_resource) -- @panel_active_conditions}
            type="button"
            phx-click="add_condition"
            phx-value-type={type}
            class="w-full text-left px-3 py-1.5 text-xs text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
          >
            {condition_type_label(type)}
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :mode, :atom, required: true

  def policy_form_actions(assigns) do
    ~H"""
    <div class="shrink-0 flex items-center justify-end gap-2 px-5 py-3 border-t border-[var(--border)] bg-[var(--surface-overlay)]">
      <button
        type="button"
        phx-click="cancel_policy_form"
        class="px-3 py-1.5 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
      >
        Cancel
      </button>
      <button
        type="submit"
        class="px-3 py-1.5 text-xs rounded-md font-medium transition-colors bg-[var(--brand)] text-white hover:bg-[var(--brand-hover)]"
      >
        {if @mode == :new, do: "Create Policy", else: "Save Changes"}
      </button>
    </div>
    """
  end

  attr :account, :any, required: true
  attr :policy, :any, required: true
  attr :providers, :list, default: []
  attr :confirm_disable_policy, :boolean, default: false
  attr :confirm_delete_policy, :boolean, default: false

  def policy_details_view(assigns) do
    ~H"""
    <div class="flex flex-col h-full overflow-hidden">
      <.policy_details_header policy={@policy} />
      <.policy_details_layout
        account={@account}
        policy={@policy}
        providers={@providers}
        confirm_disable_policy={@confirm_disable_policy}
        confirm_delete_policy={@confirm_delete_policy}
      />
    </div>
    """
  end

  attr :account, :any, required: true
  attr :policy, :any, required: true
  attr :providers, :list, default: []
  attr :confirm_disable_policy, :boolean, default: false
  attr :confirm_delete_policy, :boolean, default: false

  def policy_details_layout(assigns) do
    ~H"""
    <div class="flex flex-1 min-h-0 divide-x divide-[var(--border)]">
      <div class="flex-1 flex flex-col overflow-y-auto">
        <.policy_access_mapping account={@account} policy={@policy} />
        <.policy_conditions_list account={@account} policy={@policy} providers={@providers} />
      </div>
      <.policy_sidebar
        policy={@policy}
        confirm_disable_policy={@confirm_disable_policy}
        confirm_delete_policy={@confirm_delete_policy}
      />
    </div>
    """
  end

  attr :policy, :any, required: true

  def policy_details_header(assigns) do
    ~H"""
    <div class="shrink-0 px-5 pt-4 pb-3 border-b border-[var(--border)] bg-[var(--surface-overlay)]">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <h2 class="text-sm font-semibold text-[var(--text-primary)]">
            <%= if @policy.group do %>
              {@policy.group.name} — {@policy.resource.name}
            <% else %>
              <span class="text-amber-600">(Group deleted)</span> — {@policy.resource.name}
            <% end %>
          </h2>
          <p class="font-mono text-xs text-[var(--text-tertiary)] mt-0.5">{@policy.id}</p>
        </div>
        <div class="flex items-center gap-1.5 shrink-0">
          <button
            phx-click="open_edit_form"
            class="flex items-center gap-1 px-2.5 py-1.5 rounded text-xs border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
          >
            <.icon name="ri-pencil-line" class="w-3.5 h-3.5" /> Edit
          </button>
          <button
            phx-click="close_panel"
            class="flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
            title="Close (Esc)"
          >
            <.icon name="ri-close-line" class="w-4 h-4" />
          </button>
        </div>
      </div>
      <div class="flex items-center gap-5 mt-3 pt-3 border-t border-[var(--border)]">
        <div class="flex items-center gap-1.5">
          <span class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
            Status
          </span>
          <.status_badge status={if is_nil(@policy.disabled_at), do: :active, else: :disabled} />
        </div>
        <div class="w-px h-3.5 bg-[var(--border-strong)]"></div>
        <div class="flex items-center gap-1.5">
          <span class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
            Conditions
          </span>
          <span class="text-xs font-semibold tabular-nums text-[var(--text-primary)]">
            {length(@policy.conditions)}
          </span>
        </div>
      </div>
    </div>
    """
  end

  attr :account, :any, required: true
  attr :policy, :any, required: true

  def policy_access_mapping(assigns) do
    ~H"""
    <div class="px-5 pt-4 pb-4 border-b border-[var(--border)]">
      <div class="flex items-center justify-between mb-3">
        <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
          Access Mapping
        </h3>
      </div>
      <div class="flex items-stretch gap-2">
        <.policy_group_mapping_card account={@account} policy={@policy} />
        <.policy_mapping_arrow />
        <.policy_resource_mapping_card account={@account} policy={@policy} />
      </div>
    </div>
    """
  end

  attr :account, :any, required: true
  attr :policy, :any, required: true

  def policy_group_mapping_card(assigns) do
    ~H"""
    <%= if @policy.group do %>
      <.link
        navigate={~p"/#{@account}/groups/#{@policy.group}"}
        class="flex-1 flex items-center gap-2.5 px-3 py-2.5 rounded border border-[var(--border)] bg-[var(--surface-raised)] hover:border-[var(--border-emphasis)] hover:bg-[var(--surface)] transition-colors text-left group"
      >
        <div class="flex items-center justify-center w-7 h-7 rounded-full bg-[var(--icon-bg)] border border-[var(--border)] shrink-0">
          <.provider_icon type={provider_type_from_group(@policy.group)} class="w-4 h-4" />
        </div>
        <div class="min-w-0">
          <p class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-0.5">
            Group
          </p>
          <p class="text-sm font-medium text-[var(--text-primary)] group-hover:text-[var(--brand)] transition-colors truncate">
            {@policy.group.name}
          </p>
        </div>
      </.link>
    <% else %>
      <div class="flex-1 flex items-center gap-2.5 px-3 py-2.5 rounded border border-amber-200 bg-amber-50 dark:border-amber-900/30 dark:bg-amber-950/20">
        <.icon name="ri-error-warning-line" class="w-5 h-5 text-amber-600 shrink-0" />
        <div class="min-w-0">
          <p class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-0.5">
            Group
          </p>
          <p class="text-sm text-amber-600">Group deleted</p>
        </div>
      </div>
    <% end %>
    """
  end

  def policy_mapping_arrow(assigns) do
    ~H"""
    <div class="flex items-center shrink-0 text-[var(--text-muted)]">
      <.icon name="ri-arrow-right-long-line" class="w-5 h-5" />
    </div>
    """
  end

  attr :account, :any, required: true
  attr :policy, :any, required: true

  def policy_resource_mapping_card(assigns) do
    ~H"""
    <.link
      navigate={~p"/#{@account}/resources/#{@policy.resource_id}"}
      class="flex-1 flex items-center gap-2.5 px-3 py-2.5 rounded border border-[var(--border)] bg-[var(--surface-raised)] hover:border-[var(--border-emphasis)] hover:bg-[var(--surface)] transition-colors text-left group"
    >
      <span class={resource_type_badge_class(@policy.resource.type)}>
        {@policy.resource.type}
      </span>
      <div class="min-w-0">
        <p class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-0.5">
          Resource
        </p>
        <p class="text-sm font-medium text-[var(--text-primary)] group-hover:text-[var(--brand)] transition-colors truncate">
          {@policy.resource.name}
        </p>
        <p class="font-mono text-xs text-[var(--text-tertiary)] truncate">
          {@policy.resource.address}
        </p>
      </div>
    </.link>
    """
  end

  attr :account, :any, required: true
  attr :policy, :any, required: true
  attr :providers, :list, default: []

  def policy_conditions_list(assigns) do
    ~H"""
    <div class="px-5 pt-4 pb-4">
      <div class="flex items-center justify-between mb-3">
        <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
          Conditions
        </h3>
      </div>
      <%= if @policy.conditions == [] do %>
        <p class="text-xs text-[var(--text-muted)]">
          No conditions — access is always granted to group members.
        </p>
      <% else %>
        <ul class="space-y-2">
          <.policy_condition_row
            :for={
              condition <-
                Enum.sort_by(
                  @policy.conditions,
                  &if(&1.property == :current_utc_datetime, do: 1, else: 0)
                )
            }
            account={@account}
            condition={condition}
            providers={@providers}
          />
        </ul>
      <% end %>
    </div>
    """
  end

  attr :account, :any, required: true
  attr :condition, :map, required: true
  attr :providers, :list, default: []

  def policy_condition_row(assigns) do
    ~H"""
    <li class="flex items-start gap-3 px-3 py-2.5 rounded border border-[var(--border)] bg-[var(--surface-raised)]">
      <span class={condition_type_badge_class(@condition.property)}>
        {condition_type_label(@condition.property)}
      </span>
      <%= if @condition.property == :current_utc_datetime do %>
        <.policy_tod_condition_values values={@condition.values} />
      <% else %>
        <span class="text-xs text-[var(--text-secondary)] flex-1 min-w-0 mt-0.5">
          {condition_values_display(@condition, @providers, @account)}
        </span>
      <% end %>
    </li>
    """
  end

  attr :values, :list, required: true

  def policy_tod_condition_values(assigns) do
    assigns = assign(assigns, :tod, tod_display_rows(assigns.values))

    ~H"""
    <div class="flex-1 min-w-0 mt-0.5">
      <div class="space-y-0.5">
        <%= for {day, ranges} <- elem(@tod, 1) do %>
          <div class="flex items-baseline gap-2">
            <span class="text-[11px] font-medium text-[var(--text-secondary)] w-7 shrink-0">
              {day}
            </span>
            <span class="text-xs text-[var(--text-secondary)]">{ranges}</span>
          </div>
        <% end %>
      </div>
      <p class="text-[10px] text-[var(--text-muted)] mt-1">{elem(@tod, 0)}</p>
    </div>
    """
  end

  attr :policy, :any, required: true
  attr :confirm_disable_policy, :boolean, default: false
  attr :confirm_delete_policy, :boolean, default: false

  def policy_sidebar(assigns) do
    ~H"""
    <div class="w-1/3 shrink-0 overflow-y-auto p-4 space-y-5">
      <.policy_details_section policy={@policy} />
      <div class="border-t border-[var(--border)]"></div>
      <.policy_actions_section
        policy={@policy}
        confirm_disable_policy={@confirm_disable_policy}
      />
      <div class="border-t border-[var(--border)]"></div>
      <.policy_danger_zone confirm_delete_policy={@confirm_delete_policy} />
    </div>
    """
  end

  attr :policy, :any, required: true

  def policy_details_section(assigns) do
    ~H"""
    <section>
      <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-3">
        Details
      </h3>
      <dl class="space-y-2.5">
        <div>
          <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Policy ID</dt>
          <dd class="font-mono text-[11px] text-[var(--text-secondary)] break-all">
            {@policy.id}
          </dd>
        </div>
        <div>
          <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Created</dt>
          <dd class="text-xs text-[var(--text-secondary)]">
            <.relative_datetime datetime={@policy.inserted_at} />
          </dd>
        </div>
        <div :if={@policy.description}>
          <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Description</dt>
          <dd class="text-xs text-[var(--text-secondary)]">{@policy.description}</dd>
        </div>
      </dl>
    </section>
    """
  end

  attr :policy, :any, required: true
  attr :confirm_disable_policy, :boolean, default: false

  def policy_actions_section(assigns) do
    ~H"""
    <section>
      <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-3">
        Actions
      </h3>
      <div class="space-y-2">
        <button
          :if={is_nil(@policy.disabled_at) and not @confirm_disable_policy}
          type="button"
          phx-click="confirm_disable_policy"
          class="flex items-center gap-2 w-full px-3 py-2 rounded text-xs text-[var(--status-warning)] hover:bg-[var(--surface-raised)] transition-colors"
        >
          <.icon name="ri-pause-line" class="w-3.5 h-3.5" /> Disable policy
        </button>
        <div
          :if={is_nil(@policy.disabled_at) and @confirm_disable_policy}
          class="px-3 py-2.5 rounded border border-[var(--border)] bg-[var(--surface-raised)]"
        >
          <p class="text-xs font-medium text-[var(--text-primary)] mb-1">
            Disable this policy?
          </p>
          <p class="text-xs text-[var(--text-secondary)] mb-3">
            This will immediately revoke all access granted by it.
          </p>
          <div class="flex items-center gap-1.5">
            <button
              type="button"
              phx-click="cancel_disable_policy"
              class="px-2 py-1 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] bg-[var(--surface)] transition-colors"
            >
              Cancel
            </button>
            <button
              type="button"
              phx-click="disable_policy"
              class="px-2 py-1 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] bg-[var(--surface)] transition-colors font-medium"
            >
              Disable
            </button>
          </div>
        </div>
        <button
          :if={not is_nil(@policy.disabled_at)}
          type="button"
          phx-click="enable_policy"
          class="flex items-center gap-2 w-full px-3 py-2 rounded text-xs text-[var(--status-active)] hover:bg-[var(--surface-raised)] transition-colors"
        >
          <.icon name="ri-play-line" class="w-3.5 h-3.5" /> Enable policy
        </button>
      </div>
    </section>
    """
  end

  attr :confirm_delete_policy, :boolean, default: false

  def policy_danger_zone(assigns) do
    ~H"""
    <section>
      <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--status-error)]/60 mb-3">
        Danger Zone
      </h3>
      <button
        :if={not @confirm_delete_policy}
        type="button"
        phx-click="confirm_delete_policy"
        class="w-full text-left px-3 py-2 rounded border border-[var(--status-error)]/20 text-xs text-[var(--status-error)] hover:bg-[var(--status-error-bg)] transition-colors"
      >
        Delete policy
      </button>
      <div
        :if={@confirm_delete_policy}
        class="px-3 py-2.5 rounded border border-[var(--status-error)]/20 bg-[var(--status-error-bg)]"
      >
        <p class="text-xs font-medium text-[var(--status-error)] mb-1">
          Delete this policy?
        </p>
        <p class="text-xs text-[var(--status-error)]/70 mb-3">
          All sessions authorized by it will be expired.
        </p>
        <div class="flex items-center gap-1.5">
          <button
            type="button"
            phx-click="cancel_delete_policy"
            class="px-2 py-1 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] bg-[var(--surface)] transition-colors"
          >
            Cancel
          </button>
          <button
            type="button"
            phx-click="delete_policy"
            class="px-2 py-1 text-xs rounded border border-[var(--status-error)]/40 text-[var(--status-error)] hover:bg-[var(--status-error)]/10 bg-[var(--surface)] transition-colors font-medium"
          >
            Delete
          </button>
        </div>
      </div>
    </section>
    """
  end

  @spec condition_short_label(atom()) :: String.t()
  def condition_short_label(:client_verified), do: "Verified"
  def condition_short_label(:auth_provider_id), do: "Auth"
  def condition_short_label(:remote_ip_location_region), do: "Location"
  def condition_short_label(:remote_ip), do: "IP Range"
  def condition_short_label(:current_utc_datetime), do: "Time"
  def condition_short_label(_), do: "Condition"

  @spec resource_type_badge_class(atom()) :: String.t()
  def resource_type_badge_class(:dns),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-[var(--badge-dns-bg)] text-[var(--badge-dns-text)]"

  def resource_type_badge_class(:ip),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-[var(--badge-ip-bg)] text-[var(--badge-ip-text)]"

  def resource_type_badge_class(:cidr),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-[var(--badge-cidr-bg)] text-[var(--badge-cidr-text)]"

  def resource_type_badge_class(:internet),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-violet-100 text-violet-700 dark:bg-violet-900/30 dark:text-violet-300"

  def resource_type_badge_class(_),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-[var(--surface-raised)] text-[var(--text-secondary)]"

  @spec condition_type_badge_class(atom()) :: String.t()
  defp condition_type_badge_class(:client_verified),
    do:
      "inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium shrink-0 text-[var(--status-active)] bg-[var(--status-active-bg)]"

  defp condition_type_badge_class(:auth_provider_id),
    do:
      "inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium shrink-0 text-[var(--badge-dns-text)] bg-[var(--badge-dns-bg)]"

  defp condition_type_badge_class(:remote_ip_location_region),
    do:
      "inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium shrink-0 text-[var(--badge-ip-text)] bg-[var(--badge-ip-bg)]"

  defp condition_type_badge_class(:remote_ip),
    do:
      "inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium shrink-0 text-[var(--badge-cidr-text)] bg-[var(--badge-cidr-bg)]"

  defp condition_type_badge_class(:current_utc_datetime),
    do:
      "inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium shrink-0 text-[var(--text-secondary)] bg-[var(--surface-raised)] border border-[var(--border)]"

  defp condition_type_badge_class(_),
    do:
      "inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium shrink-0 text-[var(--text-secondary)] bg-[var(--surface-raised)]"

  @spec condition_values_display(map(), list(), any()) :: String.t()
  defp condition_values_display(%{property: :client_verified}, _providers, _account),
    do: "Client must be verified"

  defp condition_values_display(
         %{property: :auth_provider_id, values: values},
         providers,
         _account
       ) do
    names =
      values
      |> Enum.map(fn id -> Enum.find(providers, &(&1.id == id)) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.name)

    if names == [], do: Enum.join(values, ", "), else: Enum.join(names, ", ")
  end

  defp condition_values_display(
         %{property: :remote_ip_location_region, values: values},
         _providers,
         _account
       ) do
    Enum.map_join(values, ", ", fn code ->
      try do
        Portal.Geo.country_common_name!(code)
      rescue
        _ -> code
      end
    end)
  end

  defp condition_values_display(%{property: :remote_ip, values: values}, _providers, _account),
    do: Enum.join(values, ", ")

  defp condition_values_display(
         %{property: :current_utc_datetime, values: values},
         _providers,
         _account
       ) do
    values
    |> Enum.map(fn v ->
      case String.split(v, "/", parts: 3) do
        [day, time_ranges, tz] when time_ranges != "" -> {day, time_ranges, tz}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.group_by(fn {_day, _ranges, tz} -> tz end)
    |> Enum.map_join("\n", fn {tz, entries} ->
      days_str =
        Enum.map_join(entries, ", ", fn {day, ranges, _tz} ->
          "#{format_dow_abbr(day)} #{format_time_ranges(ranges)}"
        end)

      "#{days_str} (#{tz})"
    end)
  end

  defp condition_values_display(%{values: values}, _providers, _account),
    do: Enum.join(values, ", ")

  @spec tod_display_rows([String.t()]) :: {String.t(), [{String.t(), String.t()}]}
  defp tod_display_rows(values) do
    parsed =
      Enum.flat_map(values, fn v ->
        case String.split(v, "/", parts: 3) do
          [day, ranges, tz] when ranges != "" -> [{day, ranges, tz}]
          _ -> []
        end
      end)

    timezone =
      case parsed do
        [{_, _, tz} | _] -> tz
        _ -> "UTC"
      end

    rows =
      Enum.map(parsed, fn {day, ranges, _tz} ->
        {format_dow_abbr(day), format_time_ranges(ranges)}
      end)

    {timezone, rows}
  end

  @spec format_dow_abbr(String.t()) :: String.t()
  defp format_dow_abbr("M"), do: "Mon"
  defp format_dow_abbr("T"), do: "Tue"
  defp format_dow_abbr("W"), do: "Wed"
  defp format_dow_abbr("R"), do: "Thu"
  defp format_dow_abbr("F"), do: "Fri"
  defp format_dow_abbr("S"), do: "Sat"
  defp format_dow_abbr("U"), do: "Sun"
  defp format_dow_abbr(d), do: d

  @spec format_time_ranges(String.t()) :: String.t()
  defp format_time_ranges("true"), do: "all day"

  defp format_time_ranges(ranges) do
    ranges
    |> String.split(",")
    |> Enum.map_join(", ", fn range ->
      case String.split(range, "-") do
        [start, finish] -> "#{strip_seconds(start)}–#{strip_seconds(finish)}"
        _ -> range
      end
    end)
  end

  @spec strip_seconds(String.t()) :: String.t()
  defp strip_seconds(time) do
    case String.split(time, ":") do
      [h, m, _s] -> "#{h}:#{m}"
      _ -> time
    end
  end

  def conditions(assigns) do
    ~H"""
    <span :if={@conditions == []} class="text-neutral-500">
      There are no conditions defined for this policy.
    </span>
    <span :if={@conditions != []} class="flex flex-wrap">
      <span class="mr-1">This policy can be used</span>
      <.condition
        :for={condition <- @conditions}
        account={@account}
        providers={@providers}
        property={condition.property}
        operator={condition.operator}
        values={condition.values}
      />
    </span>
    """
  end

  defp condition(%{property: :remote_ip_location_region} = assigns) do
    ~H"""
    <span :if={@values != []} class="mr-1">
      <span :if={@operator == :is_in}>from</span>
      <span :if={@operator == :is_not_in}>from any counties except</span>
      <span class="font-medium">
        {@values |> Enum.map(&Portal.Geo.country_common_name!/1) |> Enum.join(", ")}
      </span>
    </span>
    """
  end

  defp condition(%{property: :remote_ip} = assigns) do
    ~H"""
    <span :if={@values != []} class="mr-1">
      <span>from IP addresses that are</span> <span :if={@operator == :is_in_cidr}>in</span>
      <span :if={@operator == :is_not_in_cidr}>not in</span>
      <span class="font-medium">{Enum.join(@values, ", ")}</span>
    </span>
    """
  end

  defp condition(%{property: :auth_provider_id} = assigns) do
    assigns =
      assign(
        assigns,
        :providers,
        assigns.values
        |> Enum.map(fn provider_id ->
          Enum.find(assigns.providers, fn provider ->
            provider.id == provider_id
          end)
        end)
        |> Enum.reject(&is_nil/1)
      )

    ~H"""
    <span :if={@providers != []} class="flex flex-wrap space-x-1 mr-1">
      <span>when signed in</span>
      <span :if={@operator == :is_in}>with</span>
      <span :if={@operator == :is_not_in}>not with</span>
      <.intersperse_blocks>
        <:separator>,</:separator>

        <:item :for={provider <- @providers}>
          <.link
            navigate={~p"/#{@account}/settings/authentication"}
            class={[link_style(), "font-medium"]}
          >
            {provider.name}
          </.link>
        </:item>
      </.intersperse_blocks>
      <span>provider(s)</span>
    </span>
    """
  end

  defp condition(%{property: :client_verified} = assigns) do
    ~H"""
    <span :if={@values != []} class="mr-1">
      <span>by clients that are</span>
      <span :if={@values == ["true"]}>verified</span>
      <span :if={@values == ["false"]}>not verified</span>
    </span>
    """
  end

  defp condition(%{property: :current_utc_datetime, values: values} = assigns) do
    assigns =
      assign_new(assigns, :tz_time_ranges_by_dow, fn ->
        {:ok, ranges} = Portal.Policies.Evaluator.parse_days_of_week_time_ranges(values)

        ranges
        |> Enum.reject(fn {_dow, time_ranges} -> time_ranges == [] end)
        |> Enum.map(fn {dow, time_ranges} -> {dow, group_ranges_by_timezone(time_ranges)} end)
        |> Enum.sort_by(fn {dow, _time_ranges_by_timezone} -> day_of_week_index(dow) end)
      end)

    ~H"""
    <span class="flex flex-wrap space-x-1 mr-1">
      on
      <.intersperse_blocks>
        <:separator>,</:separator>

        <:item :for={{day_of_week, tz_time_ranges} <- @tz_time_ranges_by_dow}>
          <span class="ml-1 font-medium">
            {day_of_week_name(day_of_week) <> "s"}
            <span :for={{timezone, time_ranges} <- tz_time_ranges}>
              {"(" <>
                Enum.map_join(time_ranges, ", ", fn {from, to} ->
                  "#{from} - #{to}"
                end) <> " #{timezone})"}
            </span>
          </span>
        </:item>
      </.intersperse_blocks>
    </span>
    """
  end

  for {code, name} <- @days_of_week do
    defp day_of_week_name(unquote(code)), do: unquote(name)
  end

  for {{code, _name}, index} <- Enum.with_index(@days_of_week) do
    def day_of_week_index(unquote(code)), do: unquote(index)
  end

  defp group_ranges_by_timezone(time_ranges) do
    Enum.reduce(time_ranges, %{}, fn {starts_at, ends_at, timezone}, acc ->
      range = {starts_at, ends_at}
      Map.update(acc, timezone, [range], fn ranges -> [range | ranges] end)
    end)
  end

  defp condition_operator_option_name(:contains), do: "contains"
  defp condition_operator_option_name(:does_not_contain), do: "does not contain"
  defp condition_operator_option_name(:is_in), do: "is in"
  defp condition_operator_option_name(:is), do: "is"
  defp condition_operator_option_name(:is_not_in), do: "is not in"
  defp condition_operator_option_name(:is_in_day_of_week_time_ranges), do: ""
  defp condition_operator_option_name(:is_in_cidr), do: "is in"
  defp condition_operator_option_name(:is_not_in_cidr), do: "is not in"

  def conditions_form(assigns) do
    assigns =
      assigns
      |> assign_new(:policy_conditions_enabled?, fn ->
        Portal.Account.policy_conditions_enabled?(assigns.account)
      end)
      |> assign_new(:enabled_conditions, fn ->
        Map.fetch!(@conditions_by_resource_type, assigns.selected_resource.type)
      end)

    ~H"""
    <fieldset class="flex flex-col gap-2 mt-4">
      <div class="flex items-center justify-between">
        <div>
          <legend class="text-xl mb-2 text-neutral-900">Conditions</legend>
          <p class="my-2 text-sm text-neutral-500">
            All conditions specified below must be met for this policy to be applied.
          </p>
        </div>
        <%= if @policy_conditions_enabled? == false do %>
          <.link navigate={~p"/#{@account}/settings/account"} class="text-sm text-primary-500">
            <.badge type="primary" title="Feature available on a higher pricing plan">
              <.icon name="ri-lock-line" class="w-3.5 h-3.5 mr-1" /> UPGRADE TO UNLOCK
            </.badge>
          </.link>
        <% end %>
      </div>

      <div class={@policy_conditions_enabled? == false && "opacity-50"}>
        <.remote_ip_location_region_condition_form
          :if={:remote_ip_location_region in @enabled_conditions}
          form={@form}
          disabled={@policy_conditions_enabled? == false}
        />
        <.remote_ip_condition_form
          :if={:remote_ip in @enabled_conditions}
          form={@form}
          disabled={@policy_conditions_enabled? == false}
        />
        <.provider_id_condition_form
          :if={:auth_provider_id in @enabled_conditions}
          form={@form}
          providers={@providers}
          disabled={@policy_conditions_enabled? == false}
        />
        <.client_verified_condition_form
          :if={:client_verified in @enabled_conditions}
          form={@form}
          disabled={@policy_conditions_enabled? == false}
        />
        <.current_utc_datetime_condition_form
          :if={:current_utc_datetime in @enabled_conditions}
          form={@form}
          timezone={@timezone}
          disabled={@policy_conditions_enabled? == false}
        />
      </div>
    </fieldset>
    """
  end

  defp remote_ip_location_region_condition_form(assigns) do
    ~H"""
    <fieldset class="mb-4">
      <% condition_form = find_condition_form(@form[:conditions], :remote_ip_location_region) %>

      <.input
        type="hidden"
        field={condition_form[:property]}
        name="policy[conditions][remote_ip_location_region][property]"
        id="policy_conditions_remote_ip_location_region_property"
        value="remote_ip_location_region"
      />

      <div
        class="hover:bg-neutral-100 cursor-pointer border border-neutral-200 shadow-b rounded-t px-4 py-2"
        phx-click={
          JS.toggle_class("hidden",
            to: "#policy_conditions_remote_ip_location_region_condition"
          )
          |> JS.toggle_class("bg-neutral-50")
          |> JS.toggle_class("ri-arrow-down-s-line",
            to: "#policy_conditions_remote_ip_location_region_chevron"
          )
          |> JS.toggle_class("ri-arrow-up-s-line",
            to: "#policy_conditions_remote_ip_location_region_chevron"
          )
        }
      >
        <legend class="flex justify-between items-center text-neutral-700">
          <span class="flex items-center">
            <.icon name="ri-map-pin-line" class="w-5 h-5 mr-2" /> Client location
          </span>
          <span class="shadow-sm bg-white w-6 h-6 flex items-center justify-center rounded-full">
            <.icon
              id="policy_conditions_remote_ip_location_region_chevron"
              name="ri-arrow-down-s-line"
              class="w-5 h-5"
            />
          </span>
        </legend>
      </div>

      <div
        id="policy_conditions_remote_ip_location_region_condition"
        class={[
          "p-4 border-neutral-200 border-l border-r border-b rounded-b",
          condition_values_empty?(condition_form) && "hidden"
        ]}
      >
        <p class="text-sm text-neutral-500 mb-4">
          Allow access when the location of the Client meets the criteria specified below.
        </p>
        <div class="grid gap-2 sm:grid-cols-5 sm:gap-4">
          <.input
            type="select"
            name="policy[conditions][remote_ip_location_region][operator]"
            id="policy_conditions_remote_ip_location_region_operator"
            field={condition_form[:operator]}
            disabled={@disabled}
            options={condition_operator_options(:remote_ip_location_region)}
            value={get_in(condition_form, [:operator, Access.key!(:value)])}
          />

          <%= for {value, index} <- Enum.with_index((condition_form[:values] && condition_form[:values].value || []) ++ [nil]) do %>
            <div :if={index > 0} class="text-right mt-3 text-sm text-neutral-900">
              or
            </div>

            <div class="col-span-4">
              <.input
                type="select"
                field={condition_form[:values]}
                name="policy[conditions][remote_ip_location_region][values][]"
                id={"policy_conditions_remote_ip_location_region_values_#{index}"}
                options={[{"Select Country", nil}] ++ Portal.Geo.all_country_options!()}
                disabled={@disabled}
                value_index={index}
                value={value}
              />
            </div>
          <% end %>
        </div>
      </div>
    </fieldset>
    """
  end

  defp remote_ip_condition_form(assigns) do
    ~H"""
    <fieldset class="mb-4">
      <% condition_form = find_condition_form(@form[:conditions], :remote_ip) %>

      <.input
        type="hidden"
        field={condition_form[:property]}
        name="policy[conditions][remote_ip][property]"
        id="policy_conditions_remote_ip_property"
        value="remote_ip"
      />

      <div
        class="hover:bg-neutral-100 cursor-pointer border border-neutral-200 shadow-b rounded-t px-4 py-2"
        phx-click={
          JS.toggle_class("hidden",
            to: "#policy_conditions_remote_ip_condition"
          )
          |> JS.toggle_class("bg-neutral-50")
          |> JS.toggle_class("ri-arrow-down-s-line",
            to: "#policy_conditions_remote_ip_chevron"
          )
          |> JS.toggle_class("ri-arrow-up-s-line",
            to: "#policy_conditions_remote_ip_chevron"
          )
        }
      >
        <legend class="flex justify-between items-center text-neutral-700">
          <span class="flex items-center">
            <.icon name="ri-global-line" class="w-5 h-5 mr-2" /> IP address
          </span>
          <span class="shadow-sm bg-white w-6 h-6 flex items-center justify-center rounded-full">
            <.icon
              id="policy_conditions_remote_ip_chevron"
              name="ri-arrow-down-s-line"
              class="w-5 h-5"
            />
          </span>
        </legend>
      </div>

      <div
        id="policy_conditions_remote_ip_condition"
        class={[
          "p-4 border-neutral-200 border-l border-r border-b rounded-b",
          condition_values_empty?(condition_form) && "hidden"
        ]}
      >
        <p class="text-sm text-neutral-500 mb-4">
          Allow access when the IP of the Client meets the criteria specified below.
        </p>
        <div class="grid gap-2 sm:grid-cols-5 sm:gap-4">
          <.input
            type="select"
            name="policy[conditions][remote_ip][operator]"
            id="policy_conditions_remote_ip_operator"
            field={condition_form[:operator]}
            disabled={@disabled}
            options={condition_operator_options(:remote_ip)}
            value={get_in(condition_form, [:operator, Access.key!(:value)])}
          />

          <%= for {value, index} <- Enum.with_index((condition_form[:values] && condition_form[:values].value || []) ++ [nil]) do %>
            <div :if={index > 0} class="text-right mt-3 text-sm text-neutral-900">
              or
            </div>

            <div class="col-span-4">
              <.input
                type="text"
                field={condition_form[:values]}
                name="policy[conditions][remote_ip][values][]"
                id={"policy_conditions_remote_ip_values_#{index}"}
                placeholder="E.g. 189.172.0.0/24 or 10.10.10.1"
                disabled={@disabled}
                value_index={index}
                value={value}
              />
            </div>
          <% end %>
        </div>
      </div>
    </fieldset>
    """
  end

  defp provider_id_condition_form(assigns) do
    ~H"""
    <fieldset class="mb-4">
      <% condition_form = find_condition_form(@form[:conditions], :auth_provider_id) %>

      <.input
        type="hidden"
        field={condition_form[:property]}
        name="policy[conditions][auth_provider_id][property]"
        id="policy_conditions_auth_provider_id_property"
        value="auth_provider_id"
      />

      <div
        class="hover:bg-neutral-100 cursor-pointer border border-neutral-200 shadow-b rounded-t px-4 py-2"
        phx-click={
          JS.toggle_class("hidden",
            to: "#policy_conditions_auth_provider_id_condition"
          )
          |> JS.toggle_class("bg-neutral-50")
          |> JS.toggle_class("ri-arrow-down-s-line",
            to: "#policy_conditions_auth_provider_id_chevron"
          )
          |> JS.toggle_class("ri-arrow-up-s-line",
            to: "#policy_conditions_auth_provider_id_chevron"
          )
        }
      >
        <legend class="flex justify-between items-center text-neutral-700">
          <span class="flex items-center">
            <.icon name="ri-id-card-line" class="w-5 h-5 mr-2" /> Authentication provider
          </span>
          <span class="shadow-sm bg-white w-6 h-6 flex items-center justify-center rounded-full">
            <.icon
              id="policy_conditions_auth_provider_id_chevron"
              name="ri-arrow-down-s-line"
              class="w-5 h-5"
            />
          </span>
        </legend>
      </div>

      <div
        id="policy_conditions_auth_provider_id_condition"
        class={[
          "p-4 border-neutral-200 border-l border-r border-b rounded-b",
          condition_values_empty?(condition_form) && "hidden"
        ]}
      >
        <p class="text-sm text-neutral-500 mb-4">
          Allow access when the provider used to sign in meets the criteria specified below.
        </p>
        <div class="grid gap-2 sm:grid-cols-5 sm:gap-4">
          <.input
            type="select"
            name="policy[conditions][auth_provider_id][operator]"
            id="policy_conditions_auth_provider_id_operator"
            field={condition_form[:operator]}
            disabled={@disabled}
            options={condition_operator_options(:auth_provider_id)}
            value={get_in(condition_form, [:operator, Access.key!(:value)])}
          />

          <%= for {value, index} <- Enum.with_index((condition_form[:values] && condition_form[:values].value || []) ++ [nil]) do %>
            <div :if={index > 0} class="text-right mt-3 text-sm text-neutral-900">
              or
            </div>

            <div class="col-span-4">
              <.input
                type="select"
                field={condition_form[:values]}
                name="policy[conditions][auth_provider_id][values][]"
                id={"policy_conditions_auth_provider_id_values_#{index}"}
                options={[{"Select Provider", nil}] ++ Enum.map(@providers, &{&1.name, &1.id})}
                disabled={@disabled}
                value_index={index}
                value={value}
              />
            </div>
          <% end %>
        </div>
      </div>
    </fieldset>
    """
  end

  defp client_verified_condition_form(assigns) do
    ~H"""
    <fieldset class="mb-4">
      <% condition_form = find_condition_form(@form[:conditions], :client_verified) %>

      <.input
        type="hidden"
        field={condition_form[:property]}
        name="policy[conditions][client_verified][property]"
        id="policy_conditions_client_verified_property"
        value="client_verified"
      />

      <.input
        type="hidden"
        name="policy[conditions][client_verified][operator]"
        id="policy_conditions_client_verified_operator"
        field={condition_form[:operator]}
        value={:is}
      />

      <div
        class="hover:bg-neutral-100 cursor-pointer border border-neutral-200 shadow-b rounded-t px-4 py-2"
        phx-click={
          JS.toggle_class("hidden",
            to: "#policy_conditions_client_verified_condition"
          )
          |> JS.toggle_class("bg-neutral-50")
          |> JS.toggle_class("ri-arrow-down-s-line",
            to: "#policy_conditions_client_verified_chevron"
          )
          |> JS.toggle_class("ri-arrow-up-s-line",
            to: "#policy_conditions_client_verified_chevron"
          )
        }
      >
        <legend class="flex justify-between items-center text-neutral-700">
          <span class="flex items-center">
            <.icon name="ri-shield-check-line" class="w-5 h-5 mr-2" /> Client verification
          </span>
          <span class="shadow-sm bg-white w-6 h-6 flex items-center justify-center rounded-full">
            <.icon
              id="policy_conditions_client_verified_chevron"
              name="ri-arrow-down-s-line"
              class="w-5 h-5"
            />
          </span>
        </legend>
      </div>

      <div
        id="policy_conditions_client_verified_condition"
        class={[
          "p-4 border-neutral-200 border-l border-r border-b rounded-b",
          condition_values_empty?(condition_form) && "hidden"
        ]}
      >
        <p class="text-sm text-neutral-500 mb-4">
          Allow access when the Client is manually verified by the administrator.
        </p>
        <div class="space-y-2" phx-update="ignore" id="conditions-client-verified-values">
          <.input
            type="checkbox"
            label="Require client verification"
            name="policy[conditions][client_verified][values][]"
            id="policy_conditions_client_verified_value"
            disabled={@disabled}
            checked={List.first(List.wrap(condition_form[:values].value)) == "true"}
            unchecked_value={nil}
          />
        </div>
      </div>
    </fieldset>
    """
  end

  defp current_utc_datetime_condition_form(assigns) do
    assigns = assign_new(assigns, :days_of_week, fn -> @days_of_week end)

    ~H"""
    <fieldset class="mb-2">
      <% condition_form = find_condition_form(@form[:conditions], :current_utc_datetime) %>

      <.input
        type="hidden"
        field={condition_form[:property]}
        name="policy[conditions][current_utc_datetime][property]"
        id="policy_conditions_current_utc_datetime_property"
        value="current_utc_datetime"
      />

      <.input
        type="hidden"
        name="policy[conditions][current_utc_datetime][operator]"
        id="policy_conditions_current_utc_datetime_operator"
        field={condition_form[:operator]}
        value={:is_in_day_of_week_time_ranges}
      />

      <div
        class="hover:bg-neutral-100 cursor-pointer border border-neutral-200 shadow-b rounded-t px-4 py-2"
        phx-click={
          JS.toggle_class("hidden",
            to: "#policy_conditions_current_utc_datetime_condition"
          )
          |> JS.toggle_class("bg-neutral-50")
          |> JS.toggle_class("ri-arrow-down-s-line",
            to: "#policy_conditions_current_utc_datetime_chevron"
          )
          |> JS.toggle_class("ri-arrow-up-s-line",
            to: "#policy_conditions_current_utc_datetime_chevron"
          )
        }
      >
        <legend class="flex justify-between items-center text-neutral-700">
          <span class="flex items-center">
            <.icon name="ri-time-line" class="w-5 h-5 mr-2" /> Current time
          </span>
          <span class="shadow-sm bg-white w-6 h-6 flex items-center justify-center rounded-full">
            <.icon
              id="policy_conditions_current_utc_datetime_chevron"
              name="ri-arrow-down-s-line"
              class="w-5 h-5"
            />
          </span>
        </legend>
      </div>

      <div
        id="policy_conditions_current_utc_datetime_condition"
        class={[
          "p-4 border-neutral-200 border-l border-r border-b rounded-b",
          condition_values_empty?(condition_form) && "hidden"
        ]}
      >
        <p class="text-sm text-neutral-500 mb-4">
          Allow access during the time windows specified below. 24hr format and multiple time ranges per day are supported.
        </p>
        <div class="space-y-2">
          <.input
            type="select"
            label="Timezone"
            name="policy[conditions][current_utc_datetime][timezone]"
            id="policy_conditions_current_utc_datetime_timezone"
            field={condition_form[:timezone]}
            options={Tzdata.zone_list()}
            disabled={@disabled}
            value={condition_form[:timezone].value || @timezone}
          />

          <div class="space-y-2">
            <.current_utc_datetime_condition_day_input
              :for={{code, _name} <- @days_of_week}
              disabled={@disabled}
              condition_form={condition_form}
              day={code}
            />
          </div>
        </div>
      </div>
    </fieldset>
    """
  end

  defp find_condition_form(form_field, property) do
    condition_form =
      form_field.value
      |> Enum.find_value(fn
        %Ecto.Changeset{} = condition ->
          if Ecto.Changeset.get_field(condition, :property) == property do
            to_form(condition)
          end

        condition ->
          if Map.get(condition, :property) == property do
            to_form(Condition.changeset(condition, %{}, 0))
          end
      end)

    condition_form || to_form(%{})
  end

  defp current_utc_datetime_condition_day_input(assigns) do
    ~H"""
    <.input
      type="text"
      label={day_of_week_name(@day)}
      field={@condition_form[:values]}
      name={"policy[conditions][current_utc_datetime][values][#{@day}]"}
      id={"policy_conditions_current_utc_datetime_values_#{@day}"}
      placeholder="E.g. 9:00-12:00, 13:00-17:00"
      value={get_datetime_range_for_day_of_week(@day, @condition_form[:values])}
      disabled={@disabled}
      value_index={day_of_week_index(@day)}
    />
    """
  end

  defp get_datetime_range_for_day_of_week(day, form_field) do
    Enum.find_value(form_field.value || [], fn dow_time_ranges ->
      case String.split(dow_time_ranges, "/", parts: 3) do
        [^day, ranges, _timezone] -> ranges
        _other -> false
      end
    end)
  end

  defp condition_operator_options(property) do
    Portal.Policies.Condition.valid_operators_for_property(property)
    |> Enum.map(&{condition_operator_option_name(&1), &1})
  end

  def options_form(assigns) do
    ~H"""
    """
  end

  @spec available_conditions(map() | nil) :: [atom()]
  def available_conditions(%{type: :internet}),
    do: [:remote_ip_location_region, :remote_ip, :auth_provider_id, :client_verified]

  def available_conditions(_resource),
    do: [
      :remote_ip_location_region,
      :remote_ip,
      :auth_provider_id,
      :client_verified,
      :current_utc_datetime
    ]

  @spec condition_type_label(atom()) :: String.t()
  def condition_type_label(:client_verified), do: "Require Verified Client"
  def condition_type_label(:auth_provider_id), do: "Authentication Provider"
  def condition_type_label(:remote_ip_location_region), do: "Client Location"
  def condition_type_label(:remote_ip), do: "IP Range"
  def condition_type_label(:current_utc_datetime), do: "Time of Day"

  @spec country_name(String.t()) :: String.t()
  def country_name(code) do
    Portal.Geo.all_country_options!()
    |> Enum.find_value(code, fn {label, c} -> if c == code, do: label end)
  end

  @condition_input_class "w-full text-xs rounded border border-[var(--border)] bg-[var(--surface-raised)] text-[var(--text-primary)] px-2 py-1.5 outline-none focus:border-[var(--control-focus)] focus:ring-1 focus:ring-[var(--control-focus)]/30 transition-colors"

  attr :type, :atom, required: true
  attr :providers, :list, default: []
  attr :conditions_state, :map, required: true

  def grant_condition_card(assigns) do
    ~H"""
    <.grant_client_verified_condition_card :if={@type == :client_verified} type={@type} />
    <.grant_ip_range_condition_card
      :if={@type == :remote_ip}
      type={@type}
      ip_range_operator={@conditions_state.ip_range_operator}
      ip_range_values={@conditions_state.ip_range_values}
      ip_range_input={@conditions_state.ip_range_input}
    />
    <.grant_location_condition_card
      :if={@type == :remote_ip_location_region}
      type={@type}
      location_operator={@conditions_state.location_operator}
      location_search={@conditions_state.location_search}
      location_values={@conditions_state.location_values}
    />
    <.grant_auth_provider_condition_card
      :if={@type == :auth_provider_id}
      type={@type}
      providers={@providers}
      auth_provider_operator={@conditions_state.auth_provider_operator}
      auth_provider_values={@conditions_state.auth_provider_values}
    />
    <.grant_tod_condition_card
      :if={@type == :current_utc_datetime}
      type={@type}
      timezone={@conditions_state.timezone}
      tod_values={@conditions_state.tod_values}
      tod_adding={@conditions_state.tod_adding}
      tod_pending={@conditions_state.tod_pending}
      tod_pending_error={@conditions_state.tod_pending_error}
    />
    """
  end

  attr :type, :atom, required: true

  defp grant_condition_card_header(assigns) do
    ~H"""
    <div class="flex items-center justify-between px-3 py-2 bg-[var(--surface-raised)] border-b border-[var(--border)]">
      <span class="text-xs font-medium text-[var(--text-primary)]">
        {condition_type_label(@type)}
      </span>
      <button
        type="button"
        phx-click="remove_condition"
        phx-value-type={@type}
        class="flex items-center justify-center w-5 h-5 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface)] transition-colors"
        title="Remove condition"
      >
        <.icon name="ri-close-line" class="w-3.5 h-3.5" />
      </button>
    </div>
    """
  end

  attr :type, :atom, required: true

  defp grant_client_verified_condition_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-[var(--border)] overflow-hidden">
      <.grant_condition_card_header type={@type} />
      <input
        type="hidden"
        name="policy[conditions][client_verified][property]"
        value="client_verified"
      />
      <input
        type="hidden"
        name="policy[conditions][client_verified][operator]"
        value="is"
      />
      <input
        type="hidden"
        name="policy[conditions][client_verified][values][]"
        value="true"
      />
    </div>
    """
  end

  attr :type, :atom, required: true
  attr :ip_range_operator, :string, default: "is_in_cidr"
  attr :ip_range_values, :list, default: []
  attr :ip_range_input, :string, default: ""

  defp grant_ip_range_condition_card(assigns) do
    assigns = assign(assigns, :input_class, @condition_input_class)

    ~H"""
    <div class="rounded-lg border border-[var(--border)] overflow-hidden">
      <.grant_condition_card_header type={@type} />
      <div class="px-3 py-2.5 space-y-2">
        <input
          type="hidden"
          name="policy[conditions][remote_ip][property]"
          value="remote_ip"
        />
        <input
          type="hidden"
          name="policy[conditions][remote_ip][operator]"
          value={@ip_range_operator}
        />
        <div class="inline-flex rounded border border-[var(--border)] overflow-hidden">
          <button
            type="button"
            phx-click="change_ip_range_operator"
            phx-value-operator="is_in_cidr"
            class={[
              "px-2 py-0.5 text-[10px] transition-colors",
              if(@ip_range_operator == "is_in_cidr",
                do: "bg-[var(--brand)] text-white",
                else: "bg-[var(--surface)] text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
              )
            ]}
          >
            is in CIDR
          </button>
          <button
            type="button"
            phx-click="change_ip_range_operator"
            phx-value-operator="is_not_in_cidr"
            class={[
              "px-2 py-0.5 text-[10px] border-l border-[var(--border)] transition-colors",
              if(@ip_range_operator == "is_not_in_cidr",
                do: "bg-[var(--brand)] text-white",
                else: "bg-[var(--surface)] text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
              )
            ]}
          >
            is not in CIDR
          </button>
        </div>
        <input
          :for={v <- @ip_range_values}
          type="hidden"
          name="policy[conditions][remote_ip][values][]"
          value={v}
        />
        <div :if={@ip_range_values != []} class="flex flex-wrap gap-1 mb-2">
          <span
            :for={v <- @ip_range_values}
            class="inline-flex items-center gap-1 pl-1.5 pr-1 py-0.5 rounded text-[10px] font-mono bg-[var(--brand-muted)] text-[var(--brand)] border border-[var(--brand)]/20"
          >
            {v}
            <button
              type="button"
              phx-click="remove_ip_range_value"
              phx-value-range={v}
              class="hover:text-[var(--status-error)] transition-colors"
            >
              <.icon name="ri-close-line" class="w-2.5 h-2.5" />
            </button>
          </span>
        </div>
        <div class="flex gap-1.5">
          <input
            type="text"
            name="_ip_range_input"
            value={@ip_range_input}
            placeholder="e.g. 10.0.0.0/8"
            phx-change="update_ip_range_input"
            phx-key="Enter"
            phx-keyup="add_ip_range_value"
            class={[@input_class, "flex-1 font-mono placeholder:text-[var(--text-muted)]"]}
          />
          <button
            type="button"
            phx-click="add_ip_range_value"
            class="px-2 py-1 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] bg-[var(--surface)] transition-colors shrink-0"
          >
            Add
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :type, :atom, required: true
  attr :location_operator, :string, default: "is_in"
  attr :location_search, :string, default: ""
  attr :location_values, :list, default: []

  defp grant_location_condition_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-[var(--border)] overflow-hidden">
      <.grant_condition_card_header type={@type} />
      <div class="px-3 py-2.5">
        <input
          type="hidden"
          name="policy[conditions][remote_ip_location_region][property]"
          value="remote_ip_location_region"
        />
        <input
          type="hidden"
          name="policy[conditions][remote_ip_location_region][operator]"
          value={@location_operator}
        />
        <input
          :for={code <- @location_values}
          type="hidden"
          name="policy[conditions][remote_ip_location_region][values][]"
          value={code}
        />
        <div class="inline-flex rounded border border-[var(--border)] overflow-hidden mb-3">
          <button
            type="button"
            phx-click="change_location_operator"
            phx-value-operator="is_in"
            class={[
              "px-2 py-0.5 text-[10px] transition-colors",
              if(@location_operator == "is_in",
                do: "bg-[var(--brand)] text-white",
                else: "bg-[var(--surface)] text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
              )
            ]}
          >
            is in
          </button>
          <button
            type="button"
            phx-click="change_location_operator"
            phx-value-operator="is_not_in"
            class={[
              "px-2 py-0.5 text-[10px] border-l border-[var(--border)] transition-colors",
              if(@location_operator == "is_not_in",
                do: "bg-[var(--brand)] text-white",
                else: "bg-[var(--surface)] text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
              )
            ]}
          >
            is not in
          </button>
        </div>
        <div :if={@location_values != []} class="flex flex-wrap gap-1 mb-2">
          <span
            :for={code <- @location_values}
            class="inline-flex items-center gap-1 pl-1.5 pr-1 py-0.5 rounded text-[10px] bg-[var(--brand-muted)] text-[var(--brand)] border border-[var(--brand)]/20"
          >
            {country_name(code)}
            <button
              type="button"
              phx-click="toggle_location_value"
              phx-value-code={code}
              class="hover:text-[var(--status-error)] transition-colors"
            >
              <.icon name="ri-close-line" class="w-2.5 h-2.5" />
            </button>
          </span>
        </div>
        <input
          type="text"
          placeholder="Search countries…"
          value={@location_search}
          phx-change="update_location_search"
          phx-debounce="150"
          name="_location_search"
          class="w-full px-2.5 py-1.5 text-xs rounded border bg-[var(--control-bg)] border-[var(--control-border)] text-[var(--text-primary)] placeholder:text-[var(--text-muted)] outline-none focus:border-[var(--control-focus)] transition-colors mb-1"
        />
        <div class="max-h-36 overflow-y-auto rounded border border-[var(--border)] bg-[var(--surface)]">
          <p
            :if={@location_search == ""}
            class="px-2.5 py-3 text-xs text-[var(--text-muted)] text-center"
          >
            Type to search countries
          </p>
          <label
            :for={
              {label, code} <-
                if @location_search == "" do
                  []
                else
                  Portal.Geo.all_country_options!()
                  |> Enum.filter(fn {l, _} ->
                    String.contains?(String.downcase(l), String.downcase(@location_search))
                  end)
                end
            }
            class="flex items-center gap-2 px-2.5 py-1.5 cursor-pointer hover:bg-[var(--surface-raised)] transition-colors"
            phx-click="toggle_location_value"
            phx-value-code={code}
          >
            <input
              type="checkbox"
              class="w-3 h-3 accent-[var(--brand)] pointer-events-none"
              readonly
              checked={code in @location_values}
            />
            <span class="text-xs text-[var(--text-secondary)]">{label}</span>
          </label>
        </div>
      </div>
    </div>
    """
  end

  attr :type, :atom, required: true
  attr :providers, :list, default: []
  attr :auth_provider_operator, :string, default: "is_in"
  attr :auth_provider_values, :list, default: []

  defp grant_auth_provider_condition_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-[var(--border)] overflow-hidden">
      <.grant_condition_card_header type={@type} />
      <div class="px-3 py-2.5 space-y-2">
        <input
          type="hidden"
          name="policy[conditions][auth_provider_id][property]"
          value="auth_provider_id"
        />
        <input
          type="hidden"
          name="policy[conditions][auth_provider_id][operator]"
          value={@auth_provider_operator}
        />
        <div class="inline-flex rounded border border-[var(--border)] overflow-hidden">
          <button
            type="button"
            phx-click="change_auth_provider_operator"
            phx-value-operator="is_in"
            class={[
              "px-2 py-0.5 text-[10px] transition-colors",
              if(@auth_provider_operator == "is_in",
                do: "bg-[var(--brand)] text-white",
                else: "bg-[var(--surface)] text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
              )
            ]}
          >
            is in
          </button>
          <button
            type="button"
            phx-click="change_auth_provider_operator"
            phx-value-operator="is_not_in"
            class={[
              "px-2 py-0.5 text-[10px] border-l border-[var(--border)] transition-colors",
              if(@auth_provider_operator == "is_not_in",
                do: "bg-[var(--brand)] text-white",
                else: "bg-[var(--surface)] text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
              )
            ]}
          >
            is not in
          </button>
        </div>
        <input
          :for={id <- @auth_provider_values}
          type="hidden"
          name="policy[conditions][auth_provider_id][values][]"
          value={id}
        />
        <div :if={@auth_provider_values != []} class="flex flex-wrap gap-1 mb-2">
          <span
            :for={p <- Enum.filter(@providers, &(&1.id in @auth_provider_values))}
            class="inline-flex items-center gap-1 pl-1.5 pr-1 py-0.5 rounded text-[10px] bg-[var(--brand-muted)] text-[var(--brand)] border border-[var(--brand)]/20"
          >
            {p.name}
            <button
              type="button"
              phx-click="toggle_auth_provider_value"
              phx-value-id={p.id}
              class="hover:text-[var(--status-error)] transition-colors"
            >
              <.icon name="ri-close-line" class="w-2.5 h-2.5" />
            </button>
          </span>
        </div>
        <div class="rounded border border-[var(--border)] bg-[var(--surface)]">
          <label
            :for={p <- @providers}
            class="flex items-center gap-2 px-2.5 py-1.5 cursor-pointer hover:bg-[var(--surface-raised)] transition-colors"
            phx-click="toggle_auth_provider_value"
            phx-value-id={p.id}
          >
            <input
              type="checkbox"
              class="w-3 h-3 accent-[var(--brand)] pointer-events-none"
              readonly
              checked={p.id in @auth_provider_values}
            />
            <span class="text-xs text-[var(--text-secondary)]">{p.name}</span>
          </label>
        </div>
      </div>
    </div>
    """
  end

  attr :type, :atom, required: true
  attr :timezone, :string, default: "UTC"
  attr :tod_values, :list, default: []
  attr :tod_adding, :boolean, default: false
  attr :tod_pending, :map, default: %{"on" => "", "off" => "", "days" => []}
  attr :tod_pending_error, :string, default: nil

  defp grant_tod_condition_card(assigns) do
    assigns = assign(assigns, :input_class, @condition_input_class)

    ~H"""
    <div class="rounded-lg border border-[var(--border)] overflow-hidden">
      <.grant_condition_card_header type={@type} />
      <div class="px-3 py-2.5 space-y-2">
        <input
          type="hidden"
          name="policy[conditions][current_utc_datetime][property]"
          value="current_utc_datetime"
        />
        <input
          type="hidden"
          name="policy[conditions][current_utc_datetime][operator]"
          value="is_in_day_of_week_time_ranges"
        />
        <select
          name="policy[conditions][current_utc_datetime][timezone]"
          class={@input_class}
        >
          <option :for={tz <- Tzdata.zone_list()} value={tz} selected={tz == @timezone}>
            {tz}
          </option>
        </select>
        <%!-- Confirmed ranges: hidden inputs for submission + compact display row --%>
        <div class="space-y-1">
          <div
            :for={{range, idx} <- Enum.with_index(@tod_values)}
            class="flex items-center gap-2"
          >
            <input
              :for={day <- range["days"]}
              type="hidden"
              name={"policy[conditions][current_utc_datetime][values][#{idx}][days][]"}
              value={day}
            />
            <input
              type="hidden"
              name={"policy[conditions][current_utc_datetime][values][#{idx}][on]"}
              value={range["on"]}
            />
            <input
              type="hidden"
              name={"policy[conditions][current_utc_datetime][values][#{idx}][off]"}
              value={range["off"]}
            />
            <div class="flex-1 flex items-center justify-between gap-2 px-2 py-1.5 rounded bg-[var(--surface-raised)] border border-[var(--border)]">
              <span class="text-[10px] font-medium text-[var(--text-primary)]">
                {format_tod_days(range["days"])}
              </span>
              <span class="text-[10px] font-medium text-[var(--text-primary)] tabular-nums shrink-0">
                {range["on"]} – {range["off"]}
              </span>
            </div>
            <button
              type="button"
              phx-click="remove_tod_range"
              phx-value-index={idx}
              class="shrink-0 p-0.5 rounded text-[var(--text-muted)] hover:text-red-500 transition-colors"
              title="Remove"
            >
              <.icon name="ri-close-line" class="w-3.5 h-3.5" />
            </button>
          </div>
        </div>
        <%!-- Add range form --%>
        <div
          :if={@tod_adding}
          id="tod_add_row"
          phx-hook="TimePicker"
          class="space-y-1.5 p-2 rounded border border-[var(--border)] bg-[var(--surface)]"
        >
          <div class="flex flex-wrap gap-1">
            <button
              :for={
                {code, label} <- [
                  {"M", "Mon"},
                  {"T", "Tue"},
                  {"W", "Wed"},
                  {"R", "Thu"},
                  {"F", "Fri"},
                  {"S", "Sat"},
                  {"U", "Sun"}
                ]
              }
              type="button"
              phx-click="toggle_tod_pending_day"
              phx-value-day={code}
              class={[
                "px-1.5 py-0.5 rounded text-[10px] font-medium border transition-colors",
                if code in @tod_pending["days"] do
                  "bg-[var(--brand)] border-[var(--brand)] text-white"
                else
                  "bg-[var(--surface-raised)] border-[var(--border)] text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
                end
              ]}
            >
              {label}
            </button>
          </div>
          <div class="flex items-start gap-1.5">
            <div class="flex flex-col items-center gap-0.5">
              <div class="flex">
                <input
                  type="time"
                  name="_tod_on"
                  id="tod_pending_on"
                  value={@tod_pending["on"]}
                  phx-change="change_tod_pending"
                  class={[
                    "shrink-0 text-xs rounded-l border border-[var(--border)] bg-[var(--surface-raised)]",
                    "text-[var(--text-primary)] px-2 py-1 outline-none focus:border-[var(--control-focus)]",
                    "focus:ring-1 focus:ring-[var(--control-focus)]/30 transition-colors",
                    "[&::-webkit-calendar-picker-indicator]:hidden"
                  ]}
                />
                <button
                  type="button"
                  data-target="pending_on"
                  class={[
                    "flex items-center px-1.5 rounded-r border border-l-0 border-[var(--border)]",
                    "bg-[var(--surface-raised)] text-[var(--text-muted)] hover:text-[var(--text-primary)]",
                    "hover:bg-[var(--surface)] transition-colors"
                  ]}
                  title="Pick start time"
                >
                  <.icon name="ri-time-line" class="w-3.5 h-3.5" />
                </button>
              </div>
              <span class="text-[9px] text-[var(--text-muted)]">on</span>
            </div>
            <span class="text-[var(--text-muted)] text-xs pt-1">–</span>
            <div class="flex flex-col items-center gap-0.5">
              <div class="flex">
                <input
                  type="time"
                  name="_tod_off"
                  id="tod_pending_off"
                  value={@tod_pending["off"]}
                  phx-change="change_tod_pending"
                  class={[
                    "shrink-0 text-xs rounded-l border border-[var(--border)] bg-[var(--surface-raised)]",
                    "text-[var(--text-primary)] px-2 py-1 outline-none focus:border-[var(--control-focus)]",
                    "focus:ring-1 focus:ring-[var(--control-focus)]/30 transition-colors",
                    "[&::-webkit-calendar-picker-indicator]:hidden"
                  ]}
                />
                <button
                  type="button"
                  data-target="pending_off"
                  class={[
                    "flex items-center px-1.5 rounded-r border border-l-0 border-[var(--border)]",
                    "bg-[var(--surface-raised)] text-[var(--text-muted)] hover:text-[var(--text-primary)]",
                    "hover:bg-[var(--surface)] transition-colors"
                  ]}
                  title="Pick end time"
                >
                  <.icon name="ri-time-line" class="w-3.5 h-3.5" />
                </button>
              </div>
              <span class="text-[9px] text-[var(--text-muted)]">off</span>
            </div>
          </div>
          <p
            :if={@tod_pending_error}
            class="flex items-center gap-1 text-[10px] text-[var(--status-error)]"
          >
            <.icon name="ri-alert-line" class="w-3 h-3 shrink-0" />
            {@tod_pending_error}
          </p>
          <div class="flex justify-end gap-1.5">
            <button
              type="button"
              phx-click="cancel_tod_range"
              class="px-2 py-1 text-xs rounded border border-[var(--border)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
            >
              Cancel
            </button>
            <button
              type="button"
              phx-click="confirm_tod_range"
              class="px-2 py-1 text-xs rounded bg-[var(--brand)] text-white hover:opacity-90 transition-opacity"
            >
              Add
            </button>
          </div>
        </div>
        <button
          :if={!@tod_adding}
          type="button"
          phx-click="start_add_tod_range"
          class={[
            "flex items-center justify-center gap-1 w-full px-2 py-1.5 rounded text-xs font-medium",
            "border border-[var(--border-strong)] text-[var(--text-secondary)]",
            "hover:border-[var(--brand)] hover:text-[var(--brand)] hover:bg-[var(--brand)]/5",
            "transition-colors"
          ]}
        >
          <.icon name="ri-add-line" class="w-3.5 h-3.5" /> Add range
        </button>
      </div>
    </div>
    """
  end

  @tod_day_order ["M", "T", "W", "R", "F", "S", "U"]
  @tod_day_names %{"M" => "Mon", "T" => "Tue", "W" => "Wed", "R" => "Thu", "F" => "Fri", "S" => "Sat", "U" => "Sun"}

  @spec format_tod_days([String.t()]) :: String.t()
  defp format_tod_days(days) do
    days
    |> Enum.sort_by(&Enum.find_index(@tod_day_order, fn d -> d == &1 end))
    |> Enum.map_join(", ", &Map.get(@tod_day_names, &1, &1))
  end

  defmodule Database do
    import Ecto.Query
    import Portal.Repo.Query
    alias Portal.{Safe, Userpass, EmailOTP, OIDC, Google, Entra, Okta}

    def all_active_providers_for_account(account, subject) do
      # Query all auth provider types that are not disabled
      userpass_query =
        from(p in Userpass.AuthProvider,
          where: p.account_id == ^account.id and not p.is_disabled
        )

      email_otp_query =
        from(p in EmailOTP.AuthProvider,
          where: p.account_id == ^account.id and not p.is_disabled
        )

      oidc_query =
        from(p in OIDC.AuthProvider,
          where: p.account_id == ^account.id and not p.is_disabled
        )

      google_query =
        from(p in Google.AuthProvider,
          where: p.account_id == ^account.id and not p.is_disabled
        )

      entra_query =
        from(p in Entra.AuthProvider,
          where: p.account_id == ^account.id and not p.is_disabled
        )

      okta_query =
        from(p in Okta.AuthProvider,
          where: p.account_id == ^account.id and not p.is_disabled
        )

      # Combine all providers from different tables using Safe
      (userpass_query |> Safe.scoped(subject, :replica) |> Safe.all()) ++
        (email_otp_query |> Safe.scoped(subject, :replica) |> Safe.all()) ++
        (oidc_query |> Safe.scoped(subject, :replica) |> Safe.all()) ++
        (google_query |> Safe.scoped(subject, :replica) |> Safe.all()) ++
        (entra_query |> Safe.scoped(subject, :replica) |> Safe.all()) ++
        (okta_query |> Safe.scoped(subject, :replica) |> Safe.all())
    end

    # Inlined from PortalWeb.Groups.Components
    def fetch_group_option(id, subject) do
      group =
        from(g in Portal.Group, as: :groups)
        |> where([groups: g], g.id == ^id)
        |> join(:left, [groups: g], d in assoc(g, :directory), as: :directory)
        |> join(:left, [directory: d], gd in Portal.Google.Directory,
          on: gd.id == d.id and d.type == :google,
          as: :google_directory
        )
        |> join(:left, [directory: d], ed in Portal.Entra.Directory,
          on: ed.id == d.id and d.type == :entra,
          as: :entra_directory
        )
        |> join(:left, [directory: d], od in Portal.Okta.Directory,
          on: od.id == d.id and d.type == :okta,
          as: :okta_directory
        )
        |> select_merge(
          [directory: d, google_directory: gd, entra_directory: ed, okta_directory: od],
          %{
            directory_name:
              fragment(
                "COALESCE(?, ?, ?, 'Firezone')",
                gd.name,
                ed.name,
                od.name
              ),
            directory_type: d.type
          }
        )
        |> Safe.scoped(subject, :replica)
        |> Safe.one!(fallback_to_primary: true)

      {:ok, group_option(group)}
    end

    def list_group_options(search_query_or_nil, subject) do
      query =
        from(g in Portal.Group, as: :groups)
        |> join(:left, [groups: g], d in assoc(g, :directory), as: :directory)
        |> join(:left, [directory: d], gd in Portal.Google.Directory,
          on: gd.id == d.id and d.type == :google,
          as: :google_directory
        )
        |> join(:left, [directory: d], ed in Portal.Entra.Directory,
          on: ed.id == d.id and d.type == :entra,
          as: :entra_directory
        )
        |> join(:left, [directory: d], od in Portal.Okta.Directory,
          on: od.id == d.id and d.type == :okta,
          as: :okta_directory
        )
        |> select_merge(
          [directory: d, google_directory: gd, entra_directory: ed, okta_directory: od],
          %{
            directory_name:
              fragment(
                "COALESCE(?, ?, ?, 'Firezone')",
                gd.name,
                ed.name,
                od.name
              ),
            directory_type: d.type
          }
        )
        |> order_by([groups: g], asc: g.name)
        |> limit(25)

      query =
        if search_query_or_nil != "" and search_query_or_nil != nil do
          from(g in query, where: fulltext_search(g.name, ^search_query_or_nil))
        else
          query
        end

      groups = query |> Safe.scoped(subject, :replica) |> Safe.all()

      # For metadata, we'll return a simple count
      metadata = %{limit: 25, count: length(groups)}

      {:ok, grouped_select_options(groups), metadata}
    end

    defp grouped_select_options(groups) do
      groups
      |> Enum.group_by(&option_groups_index_and_label/1)
      |> Enum.sort_by(fn {{options_group_index, options_group_label}, _groups} ->
        {options_group_index, options_group_label}
      end)
      |> Enum.map(fn {{_options_group_index, options_group_label}, groups} ->
        {options_group_label, groups |> Enum.sort_by(& &1.name) |> Enum.map(&group_option/1)}
      end)
    end

    defp option_groups_index_and_label(group) do
      index =
        cond do
          group_synced?(group) -> 9
          group_managed?(group) -> 1
          true -> 2
        end

      label =
        cond do
          group_synced?(group) ->
            "Synced from #{group.directory_name}"

          group_managed?(group) ->
            "Managed by Firezone"

          true ->
            "Manually managed"
        end

      {index, label}
    end

    defp group_option(group) do
      {group.id, group.name, group}
    end

    # Inlined from Portal.Actors helpers
    defp group_synced?(group), do: not is_nil(group.directory_id)
    defp group_managed?(group), do: group.type == :managed

    # Inline functions from Portal.PolicyAuthorizations
    def list_policy_authorizations_for(assoc, subject, opts \\ [])

    def list_policy_authorizations_for(
          %Portal.Policy{} = policy,
          %Portal.Authentication.Subject{} = subject,
          opts
        ) do
      Database.PolicyAuthorizationQuery.all()
      |> Database.PolicyAuthorizationQuery.by_policy_id(policy.id)
      |> list_policy_authorizations(subject, opts)
    end

    def list_policy_authorizations_for(
          %Portal.Resource{} = resource,
          %Portal.Authentication.Subject{} = subject,
          opts
        ) do
      Database.PolicyAuthorizationQuery.all()
      |> Database.PolicyAuthorizationQuery.by_resource_id(resource.id)
      |> list_policy_authorizations(subject, opts)
    end

    def list_policy_authorizations_for(
          %Portal.Device{type: :client} = client,
          %Portal.Authentication.Subject{} = subject,
          opts
        ) do
      Database.PolicyAuthorizationQuery.all()
      |> Database.PolicyAuthorizationQuery.by_client_id(client.id)
      |> list_policy_authorizations(subject, opts)
    end

    def list_policy_authorizations_for(
          %Portal.Actor{} = actor,
          %Portal.Authentication.Subject{} = subject,
          opts
        ) do
      Database.PolicyAuthorizationQuery.all()
      |> Database.PolicyAuthorizationQuery.by_actor_id(actor.id)
      |> list_policy_authorizations(subject, opts)
    end

    def list_policy_authorizations_for(
          %Portal.Device{type: :gateway} = gateway,
          %Portal.Authentication.Subject{} = subject,
          opts
        ) do
      Database.PolicyAuthorizationQuery.all()
      |> Database.PolicyAuthorizationQuery.by_gateway_id(gateway.id)
      |> list_policy_authorizations(subject, opts)
    end

    defp list_policy_authorizations(queryable, subject, opts) do
      queryable
      |> Portal.Safe.scoped(subject, :replica)
      |> Portal.Safe.list(Database.PolicyAuthorizationQuery, opts)
    end
  end

  defmodule Database.PolicyAuthorizationQuery do
    import Ecto.Query

    def all do
      from(policy_authorizations in Portal.PolicyAuthorization, as: :policy_authorizations)
    end

    def expired(queryable) do
      now = DateTime.utc_now()

      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.expires_at <= ^now
      )
    end

    def not_expired(queryable) do
      now = DateTime.utc_now()

      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.expires_at > ^now
      )
    end

    def by_id(queryable, id) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.id == ^id
      )
    end

    def by_account_id(queryable, account_id) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.account_id == ^account_id
      )
    end

    def by_token_id(queryable, token_id) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.token_id == ^token_id
      )
    end

    def by_policy_id(queryable, policy_id) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.policy_id == ^policy_id
      )
    end

    def for_cache(queryable) do
      queryable
      |> select(
        [policy_authorizations: policy_authorizations],
        {{policy_authorizations.initiating_device_id, policy_authorizations.resource_id},
         {policy_authorizations.id, policy_authorizations.expires_at}}
      )
    end

    def by_policy_group_id(queryable, group_id) do
      queryable
      |> with_joined_policy()
      |> where([policy: policy], policy.group_id == ^group_id)
    end

    def by_membership_id(queryable, membership_id) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.membership_id == ^membership_id
      )
    end

    def by_site_id(queryable, site_id) do
      queryable
      |> with_joined_site()
      |> where([site: site], site.id == ^site_id)
    end

    def by_resource_id(queryable, resource_id) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.resource_id == ^resource_id
      )
    end

    def by_not_in_resource_ids(queryable, resource_ids) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.resource_id not in ^resource_ids
      )
    end

    def by_client_id(queryable, client_id) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.initiating_device_id == ^client_id
      )
    end

    def by_actor_id(queryable, actor_id) do
      queryable
      |> with_joined_client()
      |> where([client: client], client.actor_id == ^actor_id)
    end

    def by_gateway_id(queryable, gateway_id) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.receiving_device_id == ^gateway_id
      )
    end

    def with_joined_policy(queryable) do
      with_policy_authorization_named_binding(queryable, :policy, fn queryable, binding ->
        join(
          queryable,
          :inner,
          [policy_authorizations: policy_authorizations],
          policy in assoc(policy_authorizations, ^binding),
          as: ^binding
        )
      end)
    end

    def with_joined_client(queryable) do
      with_policy_authorization_named_binding(queryable, :client, fn queryable, binding ->
        join(
          queryable,
          :inner,
          [policy_authorizations: policy_authorizations],
          client in assoc(policy_authorizations, ^binding),
          as: ^binding
        )
      end)
    end

    def with_joined_site(queryable) do
      queryable
      |> with_joined_gateway()
      |> with_policy_authorization_named_binding(:site, fn queryable, binding ->
        join(queryable, :inner, [gateway: gateway], site in assoc(gateway, :site), as: ^binding)
      end)
    end

    def with_joined_gateway(queryable) do
      with_policy_authorization_named_binding(queryable, :gateway, fn queryable, binding ->
        join(
          queryable,
          :inner,
          [policy_authorizations: policy_authorizations],
          gateway in assoc(policy_authorizations, ^binding),
          as: ^binding
        )
      end)
    end

    def with_policy_authorization_named_binding(queryable, binding, fun) do
      if has_named_binding?(queryable, binding) do
        queryable
      else
        fun.(queryable, binding)
      end
    end

    # Pagination
    def cursor_fields,
      do: [
        {:policy_authorizations, :desc, :inserted_at},
        {:policy_authorizations, :asc, :id}
      ]
  end
end
