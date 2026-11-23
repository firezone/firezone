defmodule PortalWeb.Components.AuthPage do
  @moduledoc """
  Shared pieces for the pages people see before they are signed in: sign in,
  sign up, OAuth consent and the result pages that close themselves.
  """
  use Phoenix.Component
  use PortalWeb, :verified_routes

  alias PortalWeb.Components.Core

  @doc """
  The title of a pre-login page with a one-line description under it.
  """
  attr :id, :string, default: nil
  attr :title, :string, required: true
  attr :class, :any, default: "mb-8"
  slot :inner_block, doc: "The description under the title"

  def heading(assigns) do
    ~H"""
    <div id={@id} class={@class}>
      <h1 class="text-[26px] font-bold leading-tight tracking-tight text-fg">{@title}</h1>
      <p :if={@inner_block != []} class="mt-2 text-sm leading-relaxed text-muted">
        {render_slot(@inner_block)}
      </p>
    </div>
    """
  end

  @doc """
  A small uppercase label above a block, with a rule under it.
  """
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def eyebrow(assigns) do
    ~H"""
    <p
      class={[
        "pb-2 mb-3 border-b border-rule text-[11px] font-semibold tracking-[.12em] uppercase text-muted",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  The "or" between two ways to continue.
  """
  def separator(assigns) do
    ~H"""
    <div class="flex items-center gap-3 my-6" role="separator">
      <div class="flex-1 h-px bg-hair"></div>
      <span class="text-[11px] font-semibold tracking-[.12em] uppercase text-faint">or</span>
      <div class="flex-1 h-px bg-hair"></div>
    </div>
    """
  end

  @doc """
  A numbered list of what happens next.
  """
  attr :id, :string, default: nil
  attr :class, :any, default: "mb-8"

  slot :step, required: true do
    attr :title, :string, required: true
  end

  def steps(assigns) do
    ~H"""
    <ol id={@id} class={["border-t border-rule", @class]}>
      <li
        :for={{step, index} <- Enum.with_index(@step, 1)}
        class="flex gap-4 py-3 border-b border-hair"
      >
        <span class="w-5 shrink-0 font-mono text-sm text-muted tabular-nums">{index}.</span>
        <div>
          <p class="text-sm font-medium text-fg">{step.title}</p>
          <p class="mt-0.5 text-xs leading-relaxed text-muted">{render_slot(step)}</p>
        </div>
      </li>
    </ol>
    """
  end

  @doc """
  A short list of things to check, each with an icon.
  """
  attr :title, :string, required: true
  attr :class, :any, default: "mb-8"

  slot :item, required: true do
    attr :icon, :string, required: true
  end

  def checklist(assigns) do
    ~H"""
    <div class={@class}>
      <.eyebrow>{@title}</.eyebrow>
      <ul>
        <li :for={item <- @item} class="flex items-start gap-3 py-2 border-b border-hair">
          <Core.icon name={item.icon} class="w-4 h-4 mt-0.5 shrink-0 text-muted" />
          <span class="text-sm text-fg">{render_slot(item)}</span>
        </li>
      </ul>
    </div>
    """
  end

  @doc """
  A notice box. `attn` is for a failure the person needs to act on.
  """
  attr :id, :string, default: nil
  attr :attn, :boolean, default: false
  attr :icon, :string, default: nil
  attr :class, :any, default: "mb-8"
  attr :rest, :global
  slot :inner_block, required: true

  def notice(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "flex items-start gap-3 p-4 border text-sm leading-relaxed",
        (@attn && "border-attn bg-attn-wash text-attn") || "border-hair bg-hover text-fg",
        @class
      ]}
      {@rest}
    >
      <Core.icon :if={@icon} name={@icon} class="w-4 h-4 mt-0.5 shrink-0" />
      <div class="min-w-0 flex-1">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  @doc """
  The result of a step that happened in another window, or of a link from an
  email. The page closes itself after `auto_close_after_ms` when it is set.
  """
  attr :success, :boolean, required: true
  attr :title, :string, required: true
  attr :auto_close_after_ms, :integer, default: nil
  slot :inner_block, required: true
  slot :actions

  def result(assigns) do
    ~H"""
    <div
      class="min-h-screen flex flex-col bg-bg text-fg"
      data-auto-close-window-after-ms={@auto_close_after_ms}
    >
      <div class="flex items-center gap-2.5 h-14 px-6 border-b border-hair shrink-0">
        <img src={~p"/images/logo.svg"} class="h-5 w-auto shrink-0" alt="Firezone Logo" />
        <span class="text-sm font-semibold tracking-tight">Firezone</span>
      </div>
      <div class="flex-1 flex items-center justify-center px-4 py-12">
        <div class="w-full max-w-md" role={(@success && "status") || "alert"}>
          <div class={[
            "w-10 h-10 mb-6 flex items-center justify-center border",
            (@success && "border-rule text-fg") || "border-attn text-attn"
          ]}>
            <Core.icon :if={@success} name="ri-check-line" class="w-5 h-5" />
            <Core.icon :if={!@success} name="ri-close-line" class="w-5 h-5" />
          </div>
          <h1 class="text-[26px] font-bold leading-tight tracking-tight">{@title}</h1>
          <div class="mt-3 text-sm leading-relaxed text-muted">
            {render_slot(@inner_block)}
          </div>
          <div :if={@actions != []} class="mt-8 flex flex-wrap items-center gap-3">
            {render_slot(@actions)}
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Applies the theme saved in this browser before the page paints. Pages that
  are not wrapped in the root layout render it in their own head.
  """
  attr :nonce, :string, required: true

  def theme_script(assigns) do
    ~H"""
    <script nonce={@nonce}>
      if (localStorage.theme === "dark" || (localStorage.theme !== "light" && window.matchMedia("(prefers-color-scheme: dark)").matches)) {
        document.documentElement.classList.add("dark");
      }
    </script>
    """
  end

  def input_class do
    [
      "block w-full h-10 px-3 text-sm bg-bg text-fg border border-rule",
      "placeholder:text-faint outline-none transition-colors",
      "focus:ring-1 focus:ring-fg focus:border-fg"
    ]
  end

  def primary_button_class do
    [
      "inline-flex items-center justify-center gap-2 h-10 px-4 text-sm font-semibold whitespace-nowrap",
      "bg-fg text-bg border border-fg hover:opacity-85 transition-opacity",
      "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-fg"
    ]
  end

  def outline_button_class do
    [
      "inline-flex items-center justify-center gap-2 h-10 px-4 text-sm font-medium whitespace-nowrap",
      "bg-bg text-fg border border-rule hover:bg-hover transition-colors",
      "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-fg"
    ]
  end

  @doc "A full-width outlined row: an icon, a label and a chevron."
  def option_button_class do
    [
      "group w-full flex items-center gap-3 h-12 px-4 text-sm text-fg",
      "bg-bg border border-rule hover:bg-hover transition-colors",
      "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-fg"
    ]
  end

  def option_arrow_class do
    "w-4 h-4 shrink-0 text-muted group-hover:text-fg group-hover:translate-x-0.5 transition-transform"
  end

  def link_class do
    "font-medium text-fg underline underline-offset-[3px] decoration-faint hover:decoration-fg"
  end
end
