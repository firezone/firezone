defmodule PortalWeb.Settings.Components do
  use PortalWeb, :component_library

  @doc """
  Pulsing placeholder rows shown where data will appear once it has loaded.

  Pages render it on the static render instead of querying, so the data is
  only loaded once, by the connected mount.

  ## Examples

      <Settings.Components.skeleton id="providers-skeleton" />
      <Settings.Components.skeleton id="usage-skeleton" rows={3} class="max-w-2xl" />
  """
  attr :id, :string, required: true
  attr :rows, :integer, default: 4
  attr :class, :any, default: nil

  def skeleton(assigns) do
    ~H"""
    <div id={@id} aria-hidden="true" class={["animate-pulse", @class]}>
      <div
        :for={width <- Enum.take(Stream.cycle(~w[w-48 w-36 w-56 w-40]), @rows)}
        class="border-b border-hair px-6 py-4"
      >
        <div class={["h-3 bg-hover max-w-full", width]}></div>
        <div class="mt-2 h-2 w-24 bg-hover"></div>
      </div>
    </div>
    """
  end

  @doc """
  A bordered grid of tiles, as in the mockups. Each child is a `tile/1` or a
  `type_tile/1`.

  ## Examples

      <Settings.Components.tiles>
        <Settings.Components.tile label="Plan">Team</Settings.Components.tile>
      </Settings.Components.tiles>
  """
  attr :id, :string, default: nil
  attr :cols, :string, default: "3", values: ~w[2 3 4]
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def tiles(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "grid grid-cols-1 border-t border-l border-rule",
        @cols == "2" && "sm:grid-cols-2",
        @cols == "3" && "sm:grid-cols-2 lg:grid-cols-3",
        @cols == "4" && "sm:grid-cols-2 lg:grid-cols-4",
        @class
      ]}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  One tile in `tiles/1`: an eyebrow label, then the value.
  """
  attr :id, :string, default: nil
  attr :label, :string, default: nil
  attr :icon, :string, default: nil
  attr :attn, :boolean, default: false, doc: "marks a tile that needs an action"
  attr :class, :any, default: nil
  slot :inner_block, required: true
  slot :action

  def tile(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "flex flex-col min-w-0 px-5 py-4 border-r border-b border-rule",
        @attn && "bg-attn-wash",
        @class
      ]}
    >
      <div :if={@label} class="flex items-center gap-1.5 mb-2">
        <Core.icon :if={@icon} name={@icon} class={["w-3.5 h-3.5 shrink-0", tile_icon_class(@attn)]} />
        <span class={[
          "text-[11px] font-semibold tracking-[.12em] uppercase",
          tile_label_class(@attn)
        ]}>
          {@label}
        </span>
        <span :if={@action != []} class="ml-auto">{render_slot(@action)}</span>
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  An outlined tile to pick a provider or type from. It patches to `patch` or
  runs the `phx-click` given in `rest`.

  ## Examples

      <Settings.Components.type_tile
        patch={~p"/\#{@account}/settings/authentication/google/new"}
        provider="google"
        title="Google"
      >
        Sign people in with their Google account.
      </Settings.Components.type_tile>
  """
  attr :id, :string, default: nil
  attr :patch, :string, default: nil
  attr :provider, :string, default: nil, doc: "provider key for Core.provider_icon"
  attr :icon, :string, default: nil, doc: "Remix icon name, when there is no provider icon"
  attr :title, :string, required: true
  attr :disabled, :boolean, default: false
  attr :rest, :global, include: ~w(phx-click phx-value-type phx-value-id)
  slot :inner_block, doc: "a one-line description"
  slot :badge, doc: "shown after the title, e.g. a lock or a NEW badge"

  def type_tile(%{patch: patch, disabled: false} = assigns) when is_binary(patch) do
    ~H"""
    <.link id={@id} patch={@patch} class={type_tile_class(false)} {@rest}>
      <.type_tile_body provider={@provider} icon={@icon} title={@title} badge={@badge}>
        {render_slot(@inner_block)}
      </.type_tile_body>
    </.link>
    """
  end

  def type_tile(assigns) do
    ~H"""
    <button id={@id} type="button" disabled={@disabled} class={type_tile_class(@disabled)} {@rest}>
      <.type_tile_body provider={@provider} icon={@icon} title={@title} badge={@badge}>
        {render_slot(@inner_block)}
      </.type_tile_body>
    </button>
    """
  end

  attr :provider, :string, default: nil
  attr :icon, :string, default: nil
  attr :title, :string, required: true
  attr :badge, :list, default: []
  slot :inner_block

  defp type_tile_body(assigns) do
    ~H"""
    <span class="flex items-center justify-center w-10 h-10 shrink-0 border border-hair">
      <Core.provider_icon :if={@provider} provider={@provider} size="lg" />
      <Core.icon :if={is_nil(@provider) and @icon} name={@icon} class="w-5 h-5 text-fg" />
    </span>
    <span class="flex flex-col min-w-0 text-left">
      <span class="flex items-center gap-2 text-sm font-semibold text-fg">
        {@title} {render_slot(@badge)}
      </span>
      <span :if={@inner_block != []} class="mt-0.5 text-xs text-muted">
        {render_slot(@inner_block)}
      </span>
    </span>
    """
  end

  @doc """
  The grid that holds `type_tile/1`s.
  """
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def type_grid(assigns) do
    ~H"""
    <div id={@id} class={["grid grid-cols-1 sm:grid-cols-2 gap-3", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  The scrolling body of a `Page.detail_modal`, between its header and footer.
  """
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def modal_body(assigns) do
    ~H"""
    <div id={@id} class={["flex-1 min-h-0 overflow-y-auto px-6 py-5", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  A centred empty state for a settings list.
  """
  attr :id, :string, default: nil
  attr :icon, :string, required: true
  attr :title, :string, required: true
  slot :inner_block
  slot :action

  def empty_state(assigns) do
    ~H"""
    <div id={@id} class="flex flex-col items-center justify-center gap-2 px-6 py-16 text-center">
      <Core.icon name={@icon} class="w-6 h-6 text-faint" />
      <p class="text-sm font-semibold text-fg">{@title}</p>
      <p :if={@inner_block != []} class="max-w-sm text-sm text-muted">
        {render_slot(@inner_block)}
      </p>
      <div :if={@action != []} class="mt-2">{render_slot(@action)}</div>
    </div>
    """
  end

  @doc """
  The classes for a list heading cell in a settings table.
  """
  def th_class do
    "px-6 py-2.5 text-left text-[11px] font-semibold tracking-[.12em] uppercase text-muted"
  end

  defp type_tile_class(false) do
    [
      "flex items-center gap-3 w-full px-4 py-3 border border-rule bg-bg",
      "hover:bg-hover transition-colors"
    ]
  end

  defp type_tile_class(true) do
    ["flex items-center gap-3 w-full px-4 py-3 border border-hair bg-bg opacity-60 cursor-not-allowed"]
  end

  defp tile_icon_class(true), do: "text-attn"
  defp tile_icon_class(false), do: "text-muted"

  defp tile_label_class(true), do: "text-attn"
  defp tile_label_class(false), do: "text-muted"
end
