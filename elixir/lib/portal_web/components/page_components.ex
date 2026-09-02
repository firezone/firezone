defmodule PortalWeb.PageComponents do
  use Phoenix.Component
  use PortalWeb, :verified_routes
  import PortalWeb.CoreComponents

  @doc """
  The read/write permission picker.

  Shared by the API token form and the OAuth consent screen so the two always
  look the same. They post to different fields and drive the shortcut buttons
  differently - a LiveView handles them with `phx-click`, a plain form submits
  them as a named button - but neither needs JavaScript.
  """
  attr :scopes, :list, required: true, doc: "The scopes currently selected"
  attr :field_name, :string, required: true, doc: "Name for each checkbox"
  attr :error, :string, default: nil
  attr :select_mode, :atom, default: :live, values: [:live, :submit]

  def scope_picker(assigns) do
    assigns = assign(assigns, :entities, sorted_scope_entities())

    ~H"""
    <fieldset>
      <div class="flex items-center justify-between mb-1">
        <legend class="block text-xs font-medium text-body">Permissions</legend>

        <div class="flex items-center gap-2 text-xs">
          <.scope_preset_button mode={@select_mode} preset="none">Select none</.scope_preset_button>
          <span class="text-subtle">·</span>
          <.scope_preset_button mode={@select_mode} preset="read">
            Select read-only
          </.scope_preset_button>
          <span class="text-subtle">·</span>
          <.scope_preset_button mode={@select_mode} preset="all">Select all</.scope_preset_button>
        </div>
      </div>

      <p class="mb-3 text-xs text-subtle">
        Always allow only the minimal permissions you need.
      </p>
      <!-- Submits the key even when nothing is ticked. -->
      <input type="hidden" name={@field_name} value="" />

      <div class={[
        "rounded border divide-y divide-border",
        (@error && "border-error ring-1 ring-error/30") || "border-border"
      ]}>
        <div class="flex items-center px-3 py-2 bg-raised">
          <span class="flex-1 text-xs font-medium text-subtle">Scope</span>
          <span class="w-16 text-center text-xs font-medium text-subtle">Read</span>
          <span class="w-16 text-center text-xs font-medium text-subtle">Write</span>
        </div>

        <div :for={{entity, levels} <- @entities} class="flex items-center px-3 py-2">
          <div class="flex-1 pr-4">
            <span class="block text-sm text-heading">{Portal.Scope.label(entity)}</span>
            <span class="block text-xs text-subtle">{Portal.Scope.description(entity)}</span>
          </div>

          <span :for={level <- [:read, :write]} class="w-16 flex justify-center">
            <input
              :if={level in levels}
              type="checkbox"
              name={@field_name}
              value={Portal.Scope.to_string(entity, level)}
              checked={scope_checked?(@scopes, entity, level)}
              disabled={scope_locked?(@scopes, entity, level)}
              class="w-4 h-4 text-brand border-border rounded disabled:opacity-50"
            />
          </span>
        </div>
      </div>

      <p :if={@error} class="mt-2 flex items-center gap-2 text-sm text-error">
        <.icon name="ri-alert-line" class="h-4 w-4 flex-none" />{@error}
      </p>
    </fieldset>
    """
  end

  attr :mode, :atom, required: true
  attr :preset, :string, required: true
  slot :inner_block, required: true

  defp scope_preset_button(assigns) do
    ~H"""
    <button
      type={if @mode == :live, do: "button", else: "submit"}
      phx-click={if @mode == :live, do: "select_scopes"}
      phx-value-preset={if @mode == :live, do: @preset}
      name={if @mode == :submit, do: "preset"}
      value={if @mode == :submit, do: @preset}
      class="text-brand hover:underline"
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp sorted_scope_entities do
    Enum.sort_by(Portal.Scope.levels_by_entity(), fn {entity, _levels} ->
      Portal.Scope.label(entity)
    end)
  end

  defp scope_checked?(scopes, entity, :read) do
    Portal.Scope.to_string(entity, :read) in scopes or
      Portal.Scope.to_string(entity, :write) in scopes
  end

  defp scope_checked?(scopes, entity, level),
    do: Portal.Scope.to_string(entity, level) in scopes

  # A locked box submits nothing, which is why scopes are expanded on read-back.
  defp scope_locked?(scopes, entity, :read),
    do: Portal.Scope.to_string(entity, :write) in scopes

  defp scope_locked?(_scopes, _entity, _level), do: false

  attr :id, :string, default: nil, doc: "The id of the section"
  slot :title, required: true, doc: "The title of the section to be displayed"
  slot :action, required: false, doc: "A slot for action to the right from title"

  slot :content, required: true, doc: "A slot for content of the section" do
    attr :flash, :any, doc: "The flash to be displayed above the content"
  end

  slot :help, required: false, doc: "A slot for help text to be displayed above the content"

  def section(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "mb-4 md:mb-6 bg-surface mx-2 md:mx-5 border border-border px-4 md:px-6",
        @content != [] && "pb-6"
      ]}
    >
      <.header>
        <:title>
          {render_slot(@title)}
        </:title>

        <:actions :for={action <- @action} :if={not Enum.empty?(@action)}>
          {render_slot(action)}
        </:actions>

        <:help :for={help <- @help} :if={not Enum.empty?(@help)}>
          {render_slot(help)}
        </:help>
      </.header>

      <section :for={content <- @content} class="section-body">
        <div :if={Map.get(content, :flash)} class="mb-4">
          <.flash kind={:info} flash={Map.get(content, :flash)} style="wide" />
          <.flash kind={:error} flash={Map.get(content, :flash)} style="wide" />
        </div>
        {render_slot(content)}
      </section>
    </div>
    """
  end

  slot :action, required: false, doc: "A slot for action to the right of the title"

  slot :content, required: false, doc: "A slot for content of the section" do
    attr :flash, :any, doc: "The flash to be displayed above the content"
  end

  def danger_zone(assigns) do
    ~H"""
    <.section :if={length(@action) > 0}>
      <:title>Danger Zone</:title>

      <:action :for={action <- @action} :if={not Enum.empty?(@action)}>
        {render_slot(action)}
      </:action>

      <:content :for={content <- @content}>
        {render_slot(content)}
      </:content>
    </.section>
    """
  end

  @doc """
  Renders a page header with icon, title, description, action, and stats slots.

  ## Examples

      <.page_header>
        <:icon><.icon name="ri-server-line" class="w-8 h-8 text-brand" /></:icon>
        <:title>Resources</:title>
        <:description>Network endpoints accessible through Firezone.</:description>
        <:action>
          <.add_button navigate={~p"/resources/new"}>Add Resource</.add_button>
        </:action>
        <:stats>
          <.dual_badge type="primary">
            <:left>{@resources_count}</:left>
            <:right>Total</:right>
          </.dual_badge>
        </:stats>
      </.page_header>
  """
  slot :icon, required: false, doc: "Large icon displayed beside the title"
  slot :title, required: true, doc: "The page title"
  slot :description, required: false, doc: "Short description below the title"
  slot :action, required: false, doc: "Action button(s) shown in the top-right"
  slot :stats, required: false, doc: "Count badges or other stats shown below the title row"

  def page_header(assigns) do
    ~H"""
    <div class="relative overflow-hidden px-4 pt-4 pb-3 md:px-6 md:pt-6 md:pb-4 border-b border-border bg-surface">
      <div class="absolute inset-x-0 top-0 h-[2px] bg-brand opacity-50"></div>
      <div class="flex items-start gap-5">
        <div :if={not Enum.empty?(@icon)} class="hidden md:block shrink-0 mt-0.5">
          {render_slot(@icon)}
        </div>
        <div class="flex-1 min-w-0">
          <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between sm:gap-4">
            <div class="min-w-0">
              <h1 class="text-base font-semibold text-heading">
                {render_slot(@title)}
              </h1>
              <p
                :if={not Enum.empty?(@description)}
                class="hidden md:block mt-0.5 text-sm text-body"
              >
                {render_slot(@description)}
              </p>
            </div>
            <div :if={not Enum.empty?(@action)} class="shrink-0 flex items-center gap-2">
              {render_slot(@action)}
            </div>
          </div>
          <div :if={not Enum.empty?(@stats)} class="mt-2 flex items-center gap-2 flex-wrap">
            {render_slot(@stats)}
          </div>
        </div>
      </div>
    </div>
    """
  end
end
