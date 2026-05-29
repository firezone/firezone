defmodule PortalWeb.Dev.ColorsLive do
  use PortalWeb, {:live_view, layout: {PortalWeb.Layouts, :components_preview}}

  @sections [
    %{
      label: "Brand",
      swatches: [
        %{name: "brand", class: "bg-brand", css_var: "--brand"},
        %{name: "brand-dark", class: "bg-brand-dark", css_var: "--brand-hover"},
        %{name: "brand-light", class: "bg-brand-light", css_var: "--brand-secondary"},
        %{name: "brand-subtle", class: "bg-brand-subtle", css_var: "--brand-tertiary"},
        %{name: "brand-muted", class: "bg-brand-muted", css_var: "--brand-muted"}
      ]
    },
    %{
      label: "Accent",
      swatches: [
        %{name: "accent", class: "bg-accent", css_var: "--accent"},
        %{name: "accent-dark", class: "bg-accent-dark", css_var: "--accent-hover"},
        %{name: "accent-light", class: "bg-accent-light", css_var: "--accent-secondary"},
        %{name: "accent-subtle", class: "bg-accent-subtle", css_var: "--accent-tertiary"},
        %{name: "accent-muted", class: "bg-accent-muted", css_var: "--accent-muted"}
      ]
    },
    %{
      label: "Text",
      swatches: [
        %{name: "heading", class: "bg-heading", css_var: "--text-primary"},
        %{name: "body", class: "bg-body", css_var: "--text-secondary"},
        %{name: "subtle", class: "bg-subtle", css_var: "--text-tertiary"},
        %{name: "muted", class: "bg-muted", css_var: "--text-muted"},
        %{name: "inverse", class: "bg-inverse", css_var: "--text-inverse"}
      ]
    },
    %{
      label: "Background",
      swatches: [
        %{name: "page", class: "bg-page", css_var: "--canvas"},
        %{name: "surface", class: "bg-surface", css_var: "--surface"},
        %{name: "elevated", class: "bg-elevated", css_var: "--surface-overlay"},
        %{name: "raised", class: "bg-raised", css_var: "--surface-raised"}
      ]
    },
    %{
      label: "Border",
      swatches: [
        %{name: "border", class: "bg-border", css_var: "--border"},
        %{name: "border-strong", class: "bg-border-strong", css_var: "--border-strong"},
        %{name: "border-emphasis", class: "bg-border-emphasis", css_var: "--border-emphasis"},
        %{name: "border-focus", class: "bg-border-focus", css_var: "--control-focus"}
      ]
    },
    %{
      label: "Status",
      swatches: [
        %{name: "success", class: "bg-success", css_var: "--success"},
        %{name: "success-light", class: "bg-success-light", css_var: "--success-light"},
        %{name: "info", class: "bg-info", css_var: "--info"},
        %{name: "info-light", class: "bg-info-light", css_var: "--info-light"},
        %{name: "warning", class: "bg-warning", css_var: "--warning"},
        %{name: "warning-light", class: "bg-warning-light", css_var: "--warning-light"},
        %{name: "danger", class: "bg-danger", css_var: "--danger"},
        %{name: "danger-light", class: "bg-danger-light", css_var: "--danger-light"},
        %{name: "error", class: "bg-error", css_var: "--error"},
        %{name: "error-light", class: "bg-error-light", css_var: "--error-light"},
        %{name: "neutral-status", class: "bg-neutral-status", css_var: "--neutral-status"},
        %{name: "neutral-status-light", class: "bg-neutral-status-light", css_var: "--neutral-status-light"}
      ]
    },
    %{
      label: "Controls",
      swatches: [
        %{name: "input", class: "bg-input", css_var: "--control-bg"},
        %{name: "input-border", class: "bg-input-border", css_var: "--control-border"}
      ]
    },
    %{
      label: "Badges",
      swatches: [
        %{name: "badge-dns", class: "bg-badge-dns", css_var: "--badge-dns-bg"},
        %{name: "badge-dns-text", class: "bg-badge-dns-text", css_var: "--badge-dns-text"},
        %{name: "badge-ip", class: "bg-badge-ip", css_var: "--badge-ip-bg"},
        %{name: "badge-ip-text", class: "bg-badge-ip-text", css_var: "--badge-ip-text"},
        %{name: "badge-cidr", class: "bg-badge-cidr", css_var: "--badge-cidr-bg"},
        %{name: "badge-cidr-text", class: "bg-badge-cidr-text", css_var: "--badge-cidr-text"},
        %{name: "badge-device-pool", class: "bg-badge-device-pool", css_var: "--badge-device-pool-bg"},
        %{name: "badge-device-pool-text", class: "bg-badge-device-pool-text", css_var: "--badge-device-pool-text"}
      ]
    },
    %{
      label: "Icons",
      swatches: [
        %{name: "icon", class: "bg-icon", css_var: "--icon-bg"}
      ]
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, sections: @sections, dark: false, selected: nil)}
  end

  @impl true
  def handle_event("toggle_dark", _params, socket) do
    {:noreply, assign(socket, dark: !socket.assigns.dark)}
  end

  @impl true
  def handle_event("select_swatch", %{"name" => name, "css_var" => css_var, "class" => class}, socket) do
    swatch =
      if socket.assigns.selected && socket.assigns.selected.name == name do
        nil
      else
        %{name: name, css_var: css_var, class: class}
      end

    {:noreply, assign(socket, selected: swatch)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-surface">
      <div class="max-w-5xl mx-auto px-8 py-10">
        <div class="flex items-start justify-between mb-10">
          <div>
            <h1 class="text-2xl font-semibold text-heading">Color Palette</h1>
            <p class="mt-1 text-sm text-subtle">
              Semantic color tokens mapped to Tailwind utilities via
              <code class="font-mono text-xs bg-raised px-1 py-0.5 rounded">@theme</code>.
              Click a swatch to edit its value.
            </p>
          </div>
          <button
            phx-click={JS.toggle_class("dark", to: "html") |> JS.push("toggle_dark")}
            class="flex items-center gap-2 px-3 py-1.5 rounded-lg border border-border text-sm text-body hover:bg-raised transition-colors"
          >
            <.icon name={if @dark, do: "ri-sun-line", else: "ri-moon-line"} class="w-4 h-4" />
            {if @dark, do: "Light mode", else: "Dark mode"}
          </button>
        </div>

        <div class="flex gap-8 items-start">
          <div class="flex-1 space-y-10">
            <section :for={section <- @sections}>
              <h2 class="text-xs font-semibold uppercase tracking-widest text-muted mb-4">
                {section.label}
              </h2>
              <div class="flex flex-wrap gap-4">
                <div
                  :for={swatch <- section.swatches}
                  class="flex flex-col gap-2 cursor-pointer"
                  phx-click="select_swatch"
                  phx-value-name={swatch.name}
                  phx-value-css_var={swatch.css_var}
                  phx-value-class={swatch.class}
                >
                  <div class={[
                    "w-24 h-14 rounded-lg border-2 transition-all",
                    swatch.class,
                    if(@selected && @selected.name == swatch.name,
                      do: "border-brand scale-105 shadow-lg",
                      else: "border-border hover:border-border-strong hover:scale-105"
                    )
                  ]}>
                  </div>
                  <span class={[
                    "text-[11px] font-mono",
                    if(@selected && @selected.name == swatch.name,
                      do: "text-brand font-semibold",
                      else: "text-subtle"
                    )
                  ]}>
                    {swatch.name}
                  </span>
                </div>
              </div>
            </section>
          </div>

          <div
            :if={@selected}
            class="sticky top-8 w-72 shrink-0 rounded-xl border border-border bg-raised p-5 shadow-sm"
            id="color-editor"
            phx-hook="ColorEditor"
            data-css-var={@selected.css_var}
          >
            <div class="flex items-center justify-between mb-4">
              <h3 class="text-sm font-semibold text-heading">{@selected.name}</h3>
              <button
                phx-click="select_swatch"
                phx-value-name={@selected.name}
                phx-value-css_var={@selected.css_var}
                phx-value-class={@selected.class}
                class="text-muted hover:text-body transition-colors"
              >
                <.icon name="ri-close-line" class="w-4 h-4" />
              </button>
            </div>

            <div class={["w-full h-16 rounded-lg border border-border mb-4", @selected.class]}></div>

            <p class="text-[11px] font-mono text-muted mb-4">{@selected.css_var}</p>

            <div class="space-y-4">
              <div>
                <div class="flex justify-between mb-1">
                  <label class="text-xs text-subtle">L — Lightness</label>
                  <span class="text-xs font-mono text-muted" id="l-display"></span>
                </div>
                <div class="relative h-3 rounded-full mb-1" data-gradient="l"></div>
                <input
                  type="range" min="0" max="100" step="0.1"
                  data-channel="l"
                  class="w-full accent-brand"
                />
              </div>

              <div>
                <div class="flex justify-between mb-1">
                  <label class="text-xs text-subtle">C — Chroma</label>
                </div>
                <div class="relative h-3 rounded-full mb-1" data-gradient="c"></div>
                <input
                  type="range" min="0" max="0.4" step="0.001"
                  data-channel="c"
                  class="w-full accent-brand"
                />
              </div>

              <div>
                <div class="flex justify-between mb-1">
                  <label class="text-xs text-subtle">H — Hue</label>
                </div>
                <div class="relative h-3 rounded-full mb-1" data-gradient="h"></div>
                <input
                  type="range" min="0" max="360" step="0.5"
                  data-channel="h"
                  class="w-full accent-brand"
                />
              </div>

              <div>
                <div class="flex justify-between mb-1">
                  <label class="text-xs text-subtle">Opacity</label>
                </div>
                <input
                  type="range" min="0" max="100" step="0.1"
                  data-channel="a"
                  class="w-full accent-brand"
                />
              </div>
            </div>

            <div class="mt-4 flex items-center gap-2">
              <code
                class="flex-1 text-[11px] font-mono text-subtle bg-surface rounded px-2 py-1 truncate"
                data-raw-value
              >
              </code>
              <button
                data-copy-value
                class="text-xs text-subtle hover:text-body px-2 py-1 rounded border border-border hover:border-border-strong transition-colors"
              >
                Copy
              </button>
            </div>

            <button
              data-reset
              class="mt-3 w-full text-xs text-subtle hover:text-body py-1.5 rounded border border-border hover:border-border-strong transition-colors"
            >
              Reset to default
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
