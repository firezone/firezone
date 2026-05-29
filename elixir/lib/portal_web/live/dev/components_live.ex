defmodule PortalWeb.Dev.ComponentsLive do
  use PortalWeb, {:live_view, layout: {PortalWeb.Layouts, :components_preview}}

  @components [
    %{
      group: "Components",
      id: "badge",
      label: "Badge",
      variants: [
        %{name: "Success", props: %{"type" => "success", "label" => "Success"}},
        %{name: "Danger", props: %{"type" => "danger", "label" => "Danger"}},
        %{name: "Warning", props: %{"type" => "warning", "label" => "Warning"}},
        %{name: "Info", props: %{"type" => "info", "label" => "Info"}},
        %{name: "Primary", props: %{"type" => "primary", "label" => "Primary"}},
        %{name: "Accent", props: %{"type" => "accent", "label" => "Accent"}},
        %{name: "Neutral", props: %{"type" => "neutral", "label" => "Neutral"}}
      ],
      controls: [
        %{name: "type", type: "select", options: ~w[success danger warning info primary accent neutral]},
        %{name: "label", type: "text"}
      ]
    },
    %{
      group: "Components",
      id: "button",
      label: "Button",
      variants: [
        %{
          name: "Primary",
          props: %{"style" => "primary", "size" => "md", "label" => "Save changes", "disabled" => false}
        },
        %{
          name: "Secondary",
          props: %{"style" => "secondary", "size" => "md", "label" => "Cancel", "disabled" => false}
        },
        %{
          name: "Danger",
          props: %{"style" => "danger", "size" => "md", "label" => "Delete", "disabled" => false}
        },
        %{
          name: "Small",
          props: %{"style" => "primary", "size" => "sm", "label" => "Small button", "disabled" => false}
        },
        %{
          name: "Large",
          props: %{"style" => "primary", "size" => "lg", "label" => "Large button", "disabled" => false}
        },
        %{
          name: "With Icon",
          props: %{"style" => "primary", "size" => "md", "label" => "Add Resource", "disabled" => false, "icon" => "ri-add-line"}
        },
        %{name: "Disabled", props: %{"style" => "primary", "size" => "md", "label" => "Disabled", "disabled" => true}}
      ],
      controls: [
        %{name: "label", type: "text"},
        %{name: "style", type: "select", options: ~w[primary secondary danger info warning success]},
        %{name: "size", type: "select", options: ~w[xs sm md lg xl]},
        %{name: "icon", type: "text"},
        %{name: "disabled", type: "boolean"}
      ]
    },
    %{
      group: "Components",
      id: "status_badge",
      label: "Status Badge",
      variants: [
        %{name: "Online", props: %{"status" => "online"}},
        %{name: "Healthy", props: %{"status" => "healthy"}},
        %{name: "Active", props: %{"status" => "active"}},
        %{name: "Degraded", props: %{"status" => "degraded"}},
        %{name: "Offline", props: %{"status" => "offline"}},
        %{name: "Disabled", props: %{"status" => "disabled"}},
        %{name: "Expired", props: %{"status" => "expired"}}
      ],
      controls: [
        %{
          name: "status",
          type: "select",
          options: ~w[online healthy active degraded offline disabled expired]
        }
      ]
    },
    %{
      group: "Components",
      id: "flash",
      label: "Flash",
      variants: [
        %{
          name: "Success",
          props: %{"kind" => "success", "title" => "", "message" => "Operation completed successfully."}
        },
        %{
          name: "Info",
          props: %{"kind" => "info", "title" => "", "message" => "Here is some useful information."}
        },
        %{
          name: "Warning",
          props: %{"kind" => "warning", "title" => "", "message" => "Proceed with caution."}
        },
        %{name: "Error", props: %{"kind" => "error", "title" => "", "message" => "Something went wrong."}},
        %{
          name: "With Title",
          props: %{"kind" => "success", "title" => "Changes saved", "message" => "Your settings have been updated."}
        }
      ],
      controls: [
        %{name: "kind", type: "select", options: ~w[success info warning error]},
        %{name: "title", type: "text"},
        %{name: "message", type: "text"}
      ]
    },
    %{
      group: "Components",
      id: "ping_icon",
      label: "Ping Icon",
      variants: [
        %{name: "Success", props: %{"color" => "success"}},
        %{name: "Info", props: %{"color" => "info"}},
        %{name: "Warning", props: %{"color" => "warning"}},
        %{name: "Danger", props: %{"color" => "danger"}}
      ],
      controls: [
        %{name: "color", type: "select", options: ~w[success info warning danger]}
      ]
    },
    %{
      group: "Components",
      id: "toggle",
      label: "Toggle",
      variants: [
        %{name: "Off", props: %{"checked" => false, "disabled" => false, "label" => "Enable feature"}},
        %{name: "On", props: %{"checked" => true, "disabled" => false, "label" => "Enable feature"}},
        %{name: "Disabled", props: %{"checked" => false, "disabled" => true, "label" => "Locked"}}
      ],
      controls: [
        %{name: "label", type: "text"},
        %{name: "checked", type: "boolean"},
        %{name: "disabled", type: "boolean"}
      ]
    },
    %{
      group: "Typography",
      id: "code",
      label: "Code",
      variants: [
        %{name: "Default", props: %{"content" => "mix phx.server"}}
      ],
      controls: [
        %{name: "content", type: "text"}
      ]
    },
    %{
      group: "Typography",
      id: "code_block",
      label: "Code Block",
      variants: [
        %{name: "Default", props: %{"content" => "mix deps.get\nmix ecto.setup\nmix phx.server"}}
      ],
      controls: [
        %{name: "content", type: "text"}
      ]
    },
    %{
      group: "Components",
      id: "dual_badge",
      label: "Dual Badge",
      variants: [
        %{name: "Success", props: %{"type" => "success", "left" => "Status", "right" => "Active"}},
        %{name: "Danger", props: %{"type" => "danger", "left" => "Error", "right" => "Failed"}},
        %{name: "Warning", props: %{"type" => "warning", "left" => "Alert", "right" => "Degraded"}},
        %{name: "Info", props: %{"type" => "info", "left" => "Info", "right" => "Pending"}},
        %{name: "Neutral", props: %{"type" => "neutral", "left" => "Tag", "right" => "Value"}}
      ],
      controls: [
        %{name: "type", type: "select", options: ~w[success danger warning info primary accent neutral]},
        %{name: "left", type: "text"},
        %{name: "right", type: "text"}
      ]
    },
    %{
      group: "Components",
      id: "connection_status",
      label: "Connection Status",
      variants: [
        %{name: "Online", props: %{"online" => "true"}},
        %{name: "Offline", props: %{"online" => "false"}}
      ],
      controls: [
        %{name: "online", type: "select", options: ~w[true false]}
      ]
    },
    %{
      group: "Components",
      id: "online_icon",
      label: "Online Icon",
      variants: [
        %{name: "Online", props: %{"online" => "true"}},
        %{name: "Offline", props: %{"online" => "false"}}
      ],
      controls: [
        %{name: "online", type: "select", options: ~w[true false]}
      ]
    },
    %{
      group: "Components",
      id: "icon",
      label: "Icon",
      variants: [
        %{name: "Resources", props: %{"name" => "ri-git-branch-line"}},
        %{name: "Sites", props: %{"name" => "ri-map-pin-2-line"}},
        %{name: "Policies", props: %{"name" => "ri-shield-check-line"}},
        %{name: "Actors", props: %{"name" => "ri-group-line"}},
        %{name: "Clients", props: %{"name" => "ri-device-line"}},
        %{name: "Gateways", props: %{"name" => "ri-server-line"}},
        %{name: "Settings", props: %{"name" => "ri-settings-4-line"}}
      ],
      controls: [
        %{name: "name", type: "text"}
      ]
    },
    %{
      group: "Typography",
      id: "copy",
      label: "Copy",
      variants: [
        %{name: "Default", props: %{"content" => "mix phx.server --open"}}
      ],
      controls: [
        %{name: "content", type: "text"}
      ]
    },
    %{
      group: "Layout",
      id: "page_header",
      label: "Page Header",
      variants: [
        %{name: "Default", props: %{}}
      ],
      controls: []
    },
    %{
      group: "Layout",
      id: "vertical_table",
      label: "Vertical Table",
      variants: [
        %{name: "Default", props: %{}}
      ],
      controls: []
    },
    %{
      group: "Layout",
      id: "step",
      label: "Step",
      variants: [
        %{name: "Default", props: %{"title" => "Deploy a Gateway"}}
      ],
      controls: [
        %{name: "title", type: "text"}
      ]
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    first = hd(@components)
    first_variant = hd(first.variants)

    {:ok,
     assign(socket,
       components: @components,
       search: "",
       selected_id: first.id,
       selected_variant: 0,
       props: first_variant.props,
       controls_open: true,
       dark_canvas: false
     )}
  end

  @impl true
  def handle_event("select_component", %{"id" => id}, socket) do
    component = find_component(id)
    variant = hd(component.variants)

    {:noreply,
     assign(socket,
       selected_id: id,
       selected_variant: 0,
       props: variant.props
     )}
  end

  def handle_event("select_variant", %{"index" => index}, socket) do
    index = String.to_integer(index)
    component = find_component(socket.assigns.selected_id)
    variant = Enum.at(component.variants, index)

    {:noreply, assign(socket, selected_variant: index, props: variant.props)}
  end

  def handle_event("toggle_bool_prop", %{"name" => name}, socket) do
    current = Map.get(socket.assigns.props, name, false)
    {:noreply, assign(socket, props: Map.put(socket.assigns.props, name, !current))}
  end

  def handle_event("toggle_controls", _params, socket) do
    {:noreply, assign(socket, controls_open: !socket.assigns.controls_open)}
  end

  def handle_event("toggle_dark_canvas", _params, socket) do
    {:noreply, assign(socket, dark_canvas: !socket.assigns.dark_canvas)}
  end

  def handle_event("search", %{"search" => value}, socket) do
    {:noreply, assign(socket, search: value)}
  end

  def handle_event("update_prop", %{"_target" => [key]} = params, socket) do
    {:noreply, assign(socket, props: Map.put(socket.assigns.props, key, params[key]))}
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        component: find_component(assigns.selected_id),
        filtered: filter_components(assigns.components, assigns.search)
      )

    ~H"""
    <div class="flex flex-col h-screen bg-canvas text-primary overflow-hidden">
      <%!-- Top header bar --%>
      <header class="flex items-center justify-between px-4 h-10 border-b border-border-strong bg-surface shrink-0">
        <div class="flex items-center gap-2">
          <span class="text-xs font-semibold tracking-wide text-primary uppercase">
            Component Preview
          </span>
        </div>
      </header>

      <%!-- Body --%>
      <div class="flex flex-1 min-h-0">
        <%!-- Left sidebar — canvas bg makes it recede as infrastructure --%>
        <aside class="w-56 shrink-0 flex flex-col border-r border-border-strong bg-canvas">
          <%!-- Search --%>
          <div class="flex items-center gap-2 px-4 py-3">
            <.icon name="ri-search-line" class="w-5 h-5" />
            <input
              type="text"
              value={@search}
              placeholder="Find..."
              phx-change="search"
              name="search"
              class="flex-1 bg-transparent text-xs text-primary placeholder:text-muted outline-none"
            />
          </div>

          <%!-- Tree --%>
          <nav class="flex-1 overflow-y-auto pt-4 pb-4" role="navigation" aria-label="Component stories">
            <%= for {group_name, items} <- group_components(@filtered) do %>
              <div class="mb-5">
                <p class="px-4 mb-2 text-[11px] font-semibold uppercase tracking-widest text-muted">
                  {group_name}
                </p>
                <button
                  :for={item <- items}
                  phx-click="select_component"
                  phx-value-id={item.id}
                  class={[
                    "w-full flex items-center gap-2.5 pl-4 pr-4 py-2 text-left text-sm transition-colors border-l-2",
                    item.id == @selected_id &&
                      "border-brand bg-brand-muted text-primary font-semibold",
                    item.id != @selected_id &&
                      "border-transparent text-secondary hover:text-primary hover:bg-surface/50"
                  ]}
                >
                  <span class="flex-1 truncate">{item.label}</span>
                  <span class={[
                    "font-mono text-xs tabular-nums",
                    item.id == @selected_id && "text-brand",
                    item.id != @selected_id && "text-muted"
                  ]}>
                    {length(item.variants)}
                  </span>
                </button>
              </div>
            <% end %>
          </nav>
        </aside>

        <%!-- Canvas area --%>
        <main class="flex flex-1 min-w-0">
          <div class="flex flex-col flex-1 min-w-0">
            <%!-- Canvas header --%>
            <div class="flex items-center justify-between px-4 h-11 border-b border-border border-border-strong bg-surface shrink-0">
              <div class="flex items-center gap-1.5 font-mono text-xs">
                <span class="text-muted">{@component.group}</span>
                <span class="text-muted">›</span>
                <span class="text-primary font-medium">{@component.label}</span>
              </div>
              <div class="flex items-center gap-1">
                <button
                  phx-click="toggle_dark_canvas"
                  title="Toggle canvas background"
                  class={[
                    "flex items-center justify-center w-6 h-6 rounded text-xs transition-colors",
                    @dark_canvas && "bg-neutral-800 text-neutral-200 border border-neutral-600",
                    !@dark_canvas && "text-muted hover:text-secondary hover:bg-canvas"
                  ]}
                >
                  <.icon name="ri-contrast-line" class="w-5 h-5" />
                </button>
                <button
                  phx-click="toggle_controls"
                  title="Toggle controls panel"
                  class={[
                    "flex items-center gap-1 px-2 h-6 rounded text-[11px] font-medium transition-colors",
                    @controls_open &&
                      "bg-brand-muted text-brand border border-brand-subtle",
                    !@controls_open && "text-muted hover:text-secondary hover:bg-canvas"
                  ]}
                >
                  <.icon name="ri-menu-line" class="w-3 h-3" />
                  <span>Controls</span>
                </button>
              </div>
            </div>

            <%!-- Variant tabs — underline style --%>
            <div
              class="flex items-end gap-0 px-4 h-9 bg-surface shrink-0 overflow-x-auto"
              role="tablist"
            >
              <button
                :for={{variant, index} <- Enum.with_index(@component.variants)}
                role="tab"
                aria-selected={index == @selected_variant}
                phx-click="select_variant"
                phx-value-index={index}
                class={[
                  "px-3 h-full text-xs font-medium whitespace-nowrap transition-colors border-b-2 -mb-px",
                  index == @selected_variant &&
                    "border-brand text-brand",
                  index != @selected_variant &&
                    "border-transparent text-muted hover:text-secondary hover:border-border"
                ]}
              >
                {variant.name}
              </button>
            </div>

            <%!-- Canvas stage — dot grid signals "sandbox" --%>
            <div
              class={[
                "flex-1 flex items-center justify-center overflow-auto",
                @dark_canvas && "bg-neutral-900",
                !@dark_canvas && "bg-canvas"
              ]}
              style={
                if @dark_canvas do
                  "background-image: radial-gradient(circle, rgba(255,255,255,0.06) 1px, transparent 1px); background-size: 20px 20px;"
                else
                  "background-image: radial-gradient(circle, rgba(15,23,42,0.08) 1px, transparent 1px); background-size: 20px 20px;"
                end
              }
            >
              <div class="p-12">
                <.canvas_component component_id={@selected_id} props={@props} />
              </div>
            </div>
          </div>

          <%!-- Controls panel --%>
          <aside
            :if={@controls_open}
            class="w-72 shrink-0 flex flex-col border-l border-border-strong bg-surface"
            aria-label="Component controls"
          >
            <div class="flex items-center justify-between px-4 h-11 border-b border-border border-border-strong shrink-0">
              <div class="flex items-center gap-2">
                <span class="text-sm font-semibold text-primary">Controls</span>
                <span class="font-mono text-xs text-muted tabular-nums">
                  {length(@component.controls)}
                </span>
              </div>
              <button
                phx-click="toggle_controls"
                class="text-muted hover:text-secondary w-5 h-5 flex items-center justify-center rounded hover:bg-canvas text-xs transition-colors"
                title="Close controls"
              >
                <.icon name="ri-close-line" class="" />
              </button>
            </div>
            <div class="flex-1 overflow-y-auto">
              <div
                :for={ctrl <- @component.controls}
                class="px-4 py-4 flex flex-col gap-2.5 border-b border-border border-border-strong last:border-0"
              >
                <div class="flex items-baseline gap-1.5">
                  <span class="font-mono text-xs font-medium text-secondary">{ctrl.name}</span>
                </div>
                <%= cond do %>
                  <% ctrl.type == "text" -> %>
                    <form phx-change="update_prop">
                      <input
                        type="text"
                        value={Map.get(@props, ctrl.name, "")}
                        name={ctrl.name}
                        class="w-full px-2.5 py-1.5 rounded text-xs bg-canvas border border-input-border text-primary placeholder:text-muted outline-none focus:border-brand focus:ring-1 focus:ring-brand-subtle transition-colors"
                      />
                    </form>
                  <% ctrl.type == "select" -> %>
                    <form phx-change="update_prop">
                      <select
                        name={ctrl.name}
                        class="w-full px-2.5 py-1.5 rounded text-xs bg-canvas border border-input-border text-primary outline-none focus:border-brand focus:ring-1 focus:ring-brand-subtle transition-colors cursor-pointer"
                      >
                        <option
                          :for={opt <- ctrl.options}
                          value={opt}
                          selected={Map.get(@props, ctrl.name) == opt}
                        >
                          {opt}
                        </option>
                      </select>
                    </form>
                  <% ctrl.type == "boolean" -> %>
                    <button
                      type="button"
                      phx-click="toggle_bool_prop"
                      phx-value-name={ctrl.name}
                      class="flex items-center gap-2.5 w-fit group"
                    >
                      <span class={[
                        "relative flex items-center w-8 h-4 rounded-full transition-colors duration-150",
                        Map.get(@props, ctrl.name, false) && "bg-brand",
                        !Map.get(@props, ctrl.name, false) && "bg-neutral-300 dark:bg-neutral-600"
                      ]}>
                        <span class={[
                          "absolute w-3 h-3 rounded-full bg-white shadow-sm transition-transform duration-150",
                          Map.get(@props, ctrl.name, false) && "translate-x-[17px]",
                          !Map.get(@props, ctrl.name, false) && "translate-x-0.5"
                        ]}>
                        </span>
                      </span>
                      <span class="font-mono text-xs text-secondary group-hover:text-primary transition-colors">
                        {if Map.get(@props, ctrl.name, false), do: "true", else: "false"}
                      </span>
                    </button>
                  <% true -> %>
                    <span class="text-xs text-muted">unsupported</span>
                <% end %>
              </div>
            </div>
          </aside>
        </main>
      </div>
    </div>
    """
  end

  # Canvas renders the selected component with current props
  defp canvas_component(%{component_id: "badge"} = assigns) do
    ~H"""
    <.badge type={@props["type"]}>{@props["label"]}</.badge>
    """
  end

  defp canvas_component(%{component_id: "button"} = assigns) do
    ~H"""
    <.button style={@props["style"]} size={@props["size"]} disabled={@props["disabled"]}>
      <.icon :if={@props["icon"] not in [nil, ""]} name={@props["icon"]} class="w-4 h-4" />
      {@props["label"]}
    </.button>
    """
  end

  defp canvas_component(%{component_id: "status_badge"} = assigns) do
    assigns = assign(assigns, :status, String.to_existing_atom(assigns.props["status"]))

    ~H"""
    <.status_badge status={@status} />
    """
  end

  defp canvas_component(%{component_id: "flash"} = assigns) do
    assigns = assign(assigns, :kind, String.to_existing_atom(assigns.props["kind"]))

    ~H"""
    <div class="w-96">
      <.flash kind={@kind} style="inline" title={@props["title"]}>
        {@props["message"]}
      </.flash>
    </div>
    """
  end

  defp canvas_component(%{component_id: "ping_icon"} = assigns) do
    ~H"""
    <.ping_icon color={@props["color"]} />
    """
  end

  defp canvas_component(%{component_id: "toggle"} = assigns) do
    ~H"""
    <.toggle
      id="canvas-toggle"
      name="canvas-toggle"
      value="true"
      checked={@props["checked"]}
      disabled={@props["disabled"]}
      label={@props["label"]}
    />
    """
  end

  defp canvas_component(%{component_id: "code"} = assigns) do
    ~H"""
    <.code>{@props["content"]}</.code>
    """
  end

  defp canvas_component(%{component_id: "code_block"} = assigns) do
    ~H"""
    <div class="w-96">
      <.code_block id="canvas-code-block">{@props["content"]}</.code_block>
    </div>
    """
  end

  defp canvas_component(%{component_id: "dual_badge"} = assigns) do
    ~H"""
    <.dual_badge type={@props["type"]}>
      <:left>{@props["left"]}</:left>
      <:right>{@props["right"]}</:right>
    </.dual_badge>
    """
  end

  defp canvas_component(%{component_id: "connection_status"} = assigns) do
    assigns = assign(assigns, :schema, %{online?: assigns.props["online"] == "true", last_seen_at: nil})

    ~H"""
    <.connection_status schema={@schema} class="" />
    """
  end

  defp canvas_component(%{component_id: "online_icon"} = assigns) do
    assigns = assign(assigns, :schema, %{online?: assigns.props["online"] == "true"})

    ~H"""
    <.online_icon schema={@schema} />
    """
  end

  defp canvas_component(%{component_id: "icon"} = assigns) do
    ~H"""
    <.icon name={@props["name"]} class="w-8 h-8 text-primary" />
    """
  end

  defp canvas_component(%{component_id: "copy"} = assigns) do
    ~H"""
    <.copy id="canvas-copy" class="flex items-center gap-2 font-mono text-sm text-primary">
      {@props["content"]}
    </.copy>
    """
  end

  defp canvas_component(%{component_id: "page_header"} = assigns) do
    ~H"""
    <div class="w-full max-w-2xl rounded overflow-hidden border border-border">
      <.page_header>
        <:icon><.icon name="ri-server-line" class="w-8 h-8 text-brand" /></:icon>
        <:title>Gateways</:title>
        <:description>Servers that route traffic between clients and resources.</:description>
      </.page_header>
    </div>
    """
  end

  defp canvas_component(%{component_id: "vertical_table"} = assigns) do
    ~H"""
    <div class="w-full max-w-lg rounded overflow-hidden border border-border">
      <.vertical_table>
        <.vertical_table_row>
          <:label>Name</:label>
          <:value>corp-gateway-1</:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Status</:label>
          <:value><.status_badge status={:online} /></:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Version</:label>
          <:value>1.4.2</:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Last Seen</:label>
          <:value>2 minutes ago</:value>
        </.vertical_table_row>
      </.vertical_table>
    </div>
    """
  end

  defp canvas_component(%{component_id: "step"} = assigns) do
    ~H"""
    <.step>
      <:title>{@props["title"]}</:title>
      <:content>
        <p class="text-sm text-neutral-600">Follow the instructions below to complete this step.</p>
      </:content>
    </.step>
    """
  end

  defp canvas_component(assigns) do
    ~H"""
    <p class="text-sm text-muted">No preview available.</p>
    """
  end

  defp find_component(id), do: Enum.find(@components, hd(@components), &(&1.id == id))

  defp filter_components(components, ""), do: components

  defp filter_components(components, search) do
    q = String.downcase(search)
    Enum.filter(components, &String.contains?(String.downcase(&1.label), q))
  end

  defp group_components(components) do
    components
    |> Enum.group_by(& &1.group)
    |> Enum.sort_by(fn {group, _} -> group end)
  end
end
