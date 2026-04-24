defmodule PortalWeb.PageComponents do
  use Phoenix.Component
  use PortalWeb, :verified_routes
  import PortalWeb.CoreComponents

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
        "mb-4 md:mb-6 bg-[var(--surface)] mx-2 md:mx-5 border border-[var(--border)] px-4 md:px-6",
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
  Renders a page header with icon, title, description, action, and filter slots.

  ## Examples

      <.page_header>
        <:icon><.icon name="ri-server-line" class="w-8 h-8 text-[var(--brand)]" /></:icon>
        <:title>Resources</:title>
        <:description>Network endpoints accessible through Firezone.</:description>
        <:action>
          <.add_button navigate={~p"/resources/new"}>Add Resource</.add_button>
        </:action>
      </.page_header>
  """
  slot :icon, required: false, doc: "Large icon displayed beside the title"
  slot :title, required: true, doc: "The page title"
  slot :description, required: false, doc: "Short description below the title"
  slot :action, required: false, doc: "Action button(s) shown in the top-right"
  slot :filters, required: false, doc: "Status/type filter chips shown below the title row"

  def page_header(assigns) do
    ~H"""
    <div class="relative overflow-hidden px-4 pt-4 pb-3 md:px-6 md:pt-6 md:pb-4 border-b border-[var(--border)] bg-[var(--surface)]">
      <div class="absolute inset-x-0 top-0 h-[2px] bg-[var(--brand)] opacity-50"></div>
      <div class="flex items-start gap-5">
        <div :if={not Enum.empty?(@icon)} class="hidden md:block shrink-0 mt-0.5">
          {render_slot(@icon)}
        </div>
        <div class="flex-1 min-w-0">
          <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between sm:gap-4">
            <div class="min-w-0">
              <h1 class="text-base font-semibold text-[var(--text-primary)]">
                {render_slot(@title)}
              </h1>
              <p
                :if={not Enum.empty?(@description)}
                class="hidden md:block mt-0.5 text-sm text-[var(--text-secondary)]"
              >
                {render_slot(@description)}
              </p>
            </div>
            <div :if={not Enum.empty?(@action)} class="shrink-0 flex items-center gap-2">
              {render_slot(@action)}
            </div>
          </div>
          <div :if={not Enum.empty?(@filters)} class="mt-3 flex items-center gap-2 flex-wrap">
            {render_slot(@filters)}
          </div>
        </div>
      </div>
    </div>
    """
  end
end
