defmodule PortalWeb.Policies.PostureComponents do
  use PortalWeb, :component_library
  alias Portal.Policies.Postures.Checks
  alias PortalWeb.Policies.Postures

  @input_class "text-xs rounded border border-border bg-raised text-heading px-2 py-1 outline-none focus:border-border-focus focus:ring-1 focus:ring-border-focus/30 transition-colors"
  @small_button_class "flex items-center gap-1 px-2 py-1 rounded text-[10px] border border-border-strong text-body hover:text-heading hover:border-border-emphasis bg-surface transition-colors"
  @editor_class "font-mono text-xs leading-5 px-2 py-1.5 whitespace-pre"
  @mark_class "underline decoration-wavy decoration-error underline-offset-2 bg-error/10"

  @provider_labels %{
    "firezone" => "Firezone",
    "intune" => "Intune",
    "iru" => "Iru",
    "defender" => "Defender",
    "santa" => "Santa",
    "sentinelone" => "SentinelOne"
  }

  @operator_labels %{
    "eq" => "=",
    "ne" => "≠",
    "gt" => ">",
    "gte" => "≥",
    "lt" => "<",
    "lte" => "≤",
    "is_in_cidr" => "is in CIDR",
    "is_not_in_cidr" => "is not in CIDR"
  }

  attr :id, :string, required: true
  attr :account, :any, required: true
  attr :state, :map, required: true
  attr :mode, :atom, default: :new

  def postures_section(assigns) do
    ~H"""
    <div :if={@state.availability != :hidden} id={@id} class="border-t border-border pt-4">
      <div class="flex items-center justify-between mb-3">
        <h4 class="text-[10px] font-semibold tracking-widest uppercase text-subtle">
          Device posture
          <span class="ml-1 font-normal normal-case tracking-normal text-muted">
            (optional)
          </span>
        </h4>
        <div :if={@state.availability == :enabled} class="inline-flex rounded border border-border overflow-hidden">
          <button
            type="button"
            phx-click="postures_tab"
            phx-value-tab="simple"
            class={pill_class(@state.tab == :simple)}
          >
            Simple
          </button>
          <button
            type="button"
            phx-click="postures_tab"
            phx-value-tab="builder"
            class={[pill_class(@state.tab == :builder), "border-l border-border"]}
          >
            Builder
          </button>
          <button
            type="button"
            phx-click="postures_tab"
            phx-value-tab="json"
            class={[pill_class(@state.tab == :json), "border-l border-border"]}
          >
            JSON
          </button>
        </div>
      </div>
      <p
        :if={@state.availability == :enabled and not @state.trust_anchors?}
        class="mb-3 flex items-start gap-1.5 rounded border border-amber-200 bg-amber-50 px-2.5 py-2 text-xs text-amber-700 dark:border-amber-800 dark:bg-amber-950/30 dark:text-amber-400"
      >
        <.icon name="ri-alert-line" class="w-3.5 h-3.5 shrink-0 mt-0.5" />
        <span>
          No trust anchors are defined. Device matching is based on Firezone-reported attributes only.
          <.website_link path="/kb/device-trust" fragment="device-attributes" class="font-medium underline hover:no-underline">
            Learn more
          </.website_link>
        </span>
      </p>
      <p :if={@mode == :edit and @state.availability == :enabled} class="mb-3 text-xs text-warning">
        Saving a change here revokes this policy's active authorizations, so sessions that rely on it are
        interrupted until the client reconnects.
      </p>
      <%= if @state.availability == :locked do %>
        <.upgrade_locked_section
          account={@account}
          message="Upgrade your plan to unlock device posture checks."
          description="Require devices to pass MDM and EDR checks before access is granted."
          data-locked-section="device-posture"
        >
          <.postures_placeholder />
        </.upgrade_locked_section>
      <% else %>
        <input type="hidden" name="policy[postures]" value={Postures.hidden_value(@state)} />
        <.postures_simple :if={@state.tab == :simple} id={@id <> "-simple"} state={@state} />
        <div :if={@state.tab == :builder}>
          <.postures_group node={@state.tree} root?={true} state={@state} />
          <p :if={@state.root_error} class="mt-2 text-xs text-error">{error_message({nil, @state.root_error})}</p>
          <p :if={@state.json_notice} class="mt-2 text-xs text-warning">{@state.json_notice}</p>
        </div>
        <.postures_json_editor :if={@state.tab == :json} id={@id <> "-json"} state={@state} />
      <% end %>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :state, :map, required: true

  def postures_simple(assigns) do
    {enabled, notice} =
      case Postures.simple_checks(assigns.state) do
        {:ok, names} -> {names, nil}
        :custom -> {[], "This policy uses custom rules. Edit them in the Builder or JSON tab."}
      end

    assigns = assign(assigns, enabled: enabled, notice: notice)

    ~H"""
    <div id={@id} class="rounded-lg border border-border overflow-hidden">
      <p :if={@notice} class="px-3 py-2 text-xs text-warning border-b border-border bg-raised">{@notice}</p>
      <p :if={@state.json_notice} class="px-3 py-2 text-xs text-warning border-b border-border bg-raised">{@state.json_notice}</p>
      <table class="w-full text-xs">
        <thead class="bg-raised text-[10px] font-semibold tracking-widest uppercase text-subtle">
          <tr>
            <th class="px-3 py-2 text-left w-12"></th>
            <th class="px-3 py-2 text-left">Check</th>
            <th class="px-3 py-2 text-left w-28">Providers</th>
            <th class="px-3 py-2 text-left w-28">Platforms</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-border">
          <tr :for={check <- Checks.all()} class={[not Postures.check_available?(@state, check) && "opacity-60"]}>
            <td class="px-3 py-2">
              <.toggle
                id={"#{@id}-#{check.name}"}
                size="sm"
                checked={check.name in @enabled}
                disabled={not is_nil(@notice) or not Postures.check_available?(@state, check)}
                phx-click="postures_toggle_check"
                phx-value-name={check.name}
              />
            </td>
            <td class="px-3 py-2">
              <div class="font-medium text-heading">{check.label}</div>
              <div class="text-muted">{check.description}</div>
              <div :if={not Postures.check_available?(@state, check)} class="text-[10px] text-muted mt-0.5">
                Connect {check.providers |> Enum.map(&provider_label(Atom.to_string(&1))) |> Enum.join(" or ")} to use this check.
              </div>
            </td>
            <td class="px-3 py-2">
              <div class="flex items-center gap-1.5">
                <.provider_icon
                  :for={provider <- check.providers}
                  provider={Atom.to_string(provider)}
                  size="xs"
                  title={provider_label(Atom.to_string(provider))}
                />
              </div>
            </td>
            <td class="px-3 py-2">
              <div class="flex items-center gap-1.5 text-body">
                <.icon
                  :for={{icon, title} <- platform_icons(check.platforms)}
                  name={icon}
                  title={title}
                  class="w-3.5 h-3.5"
                />
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  def postures_placeholder(assigns) do
    ~H"""
    <p class="text-xs text-muted text-center py-4 rounded-lg border border-dashed border-border">
      No posture rules — any device is allowed
    </p>
    """
  end

  attr :node, :map, required: true
  attr :root?, :boolean, default: false
  attr :state, :map, required: true

  def postures_group(assigns) do
    assigns =
      assigns
      |> assign(:error, Map.get(assigns.state.errors, assigns.node.id))
      |> assign(:can_add_rule?, Postures.can_add_rule?(assigns.state, assigns.node.id))
      |> assign(:can_add_group?, Postures.can_add_group?(assigns.state, assigns.node.id))
      |> assign(:small_button_class, @small_button_class)

    ~H"""
    <div
      id={"posture-node-#{@node.id}"}
      class={[
        "rounded-lg border",
        if(@root?, do: "border-dashed border-border", else: "border-border bg-raised/40"),
        @error && "border-error/60"
      ]}
    >
      <div class="flex items-center gap-1.5 px-2 py-1.5 flex-wrap">
        <.postures_not_toggle node={@node} />
        <div class="inline-flex rounded border border-border overflow-hidden">
          <button
            type="button"
            phx-click="postures_set_op"
            phx-value-id={@node.id}
            phx-value-op="and"
            class={pill_class(@node.op == "and")}
          >
            all of
          </button>
          <button
            type="button"
            phx-click="postures_set_op"
            phx-value-id={@node.id}
            phx-value-op="or"
            class={[pill_class(@node.op == "or"), "border-l border-border"]}
          >
            any of
          </button>
        </div>
        <span class="text-[10px] text-muted">
          {if @node.op == "and", do: "every rule must hold", else: "one rule is enough"}
        </span>
        <div class="ml-auto flex items-center gap-1">
          <span :if={not @can_add_group?} class="text-[10px] text-muted">
            {if @can_add_rule?, do: "Nesting limit reached", else: "Rule limit reached"}
          </span>
          <button
            :if={@can_add_rule?}
            type="button"
            phx-click="postures_add_rule"
            phx-value-id={@node.id}
            class={@small_button_class}
          >
            <.icon name="ri-add-line" class="w-2.5 h-2.5" /> Rule
          </button>
          <button
            :if={@can_add_rule?}
            type="button"
            phx-click="postures_add_check"
            phx-value-id={@node.id}
            class={@small_button_class}
          >
            <.icon name="ri-checkbox-circle-line" class="w-2.5 h-2.5" /> Check
          </button>
          <button
            :if={@can_add_group?}
            type="button"
            phx-click="postures_add_group"
            phx-value-id={@node.id}
            class={@small_button_class}
          >
            <.icon name="ri-node-tree" class="w-2.5 h-2.5" /> Group
          </button>
          <button
            :if={not @root?}
            type="button"
            phx-click="postures_remove"
            phx-value-id={@node.id}
            title="Remove group"
            class="flex items-center justify-center w-5 h-5 rounded text-subtle hover:text-heading hover:bg-surface transition-colors"
          >
            <.icon name="ri-close-line" class="w-3.5 h-3.5" />
          </button>
        </div>
      </div>
      <div :if={@root? and @node.children == []} class="px-2 pb-2">
        <.postures_placeholder />
      </div>
      <div :if={@node.children != []} class="px-2 pb-2 space-y-2">
        <%= for child <- @node.children do %>
          <.postures_group :if={child.kind == :group} node={child} state={@state} />
          <.postures_check :if={child.kind == :check} node={child} errors={@state.errors} />
          <.postures_leaf :if={child.kind == :leaf} node={child} errors={@state.errors} />
        <% end %>
      </div>
      <p :if={@error} class="px-2 pb-2 text-xs text-error">{error_message(@error)}</p>
    </div>
    """
  end

  attr :node, :map, required: true
  attr :errors, :map, required: true

  def postures_leaf(assigns) do
    node = assigns.node
    type = Postures.field_type(node.provider, node.field)

    assigns =
      assigns
      |> assign(:error, Map.get(assigns.errors, node.id))
      |> assign(:input_class, @input_class)
      |> assign(:small_button_class, @small_button_class)
      |> assign(:select_class, [@input_class, "pr-8"])
      |> assign(:type, type)
      |> assign(:providers, with_current(Postures.providers(), node.provider))
      |> assign(:fields, with_current(Postures.fields(node.provider), node.field))
      |> assign(:operators, with_current(Postures.operators(node.provider, node.field), node.op))
      |> assign(:boolean_value?, type == :boolean and not Postures.list_operator?(node.op))
      |> assign(:list_value?, Postures.list_operator?(node.op))

    ~H"""
    <div
      id={"posture-node-#{@node.id}"}
      class={["rounded-lg border bg-surface px-2 py-2", if(@error, do: "border-error/60", else: "border-border")]}
    >
      <div class="flex items-center gap-1.5 flex-wrap">
        <.postures_not_toggle node={@node} />
        <select name={"_postures[#{@node.id}][provider]"} phx-change="postures_change" class={@select_class}>
          <option :for={provider <- @providers} value={provider} selected={provider == @node.provider}>
            {provider_label(provider)}
          </option>
        </select>
        <select name={"_postures[#{@node.id}][field]"} phx-change="postures_change" class={[@select_class, "font-mono"]}>
          <option :for={field <- @fields} value={field} selected={field == @node.field}>
            {field}
          </option>
        </select>
        <select name={"_postures[#{@node.id}][op]"} phx-change="postures_change" class={@select_class}>
          <option :for={op <- @operators} value={op} selected={op == @node.op}>
            {operator_label(op)}
          </option>
        </select>
        <%= if Postures.takes_value?(@node.op) do %>
          <select
            :if={@boolean_value?}
            name={"_postures[#{@node.id}][value]"}
            phx-change="postures_change"
            class={@select_class}
          >
            <option value="true" selected={@node.value == "true"}>true</option>
            <option value="false" selected={@node.value == "false"}>false</option>
          </select>
          <input
            :if={not @boolean_value? and not @list_value?}
            type="text"
            name={"_postures[#{@node.id}][value]"}
            value={@node.value}
            placeholder={value_placeholder(@type, @node.op)}
            phx-change="postures_change"
            phx-debounce="blur"
            autocomplete="off"
            class={[@input_class, "flex-1 min-w-32 font-mono"]}
          />
          <div :if={@list_value?} class="flex flex-1 min-w-48 flex-wrap items-center gap-1">
            <span
              :for={value <- @node.values}
              class="inline-flex items-center gap-1 pl-1.5 pr-1 py-0.5 rounded text-[10px] font-mono bg-brand-muted text-brand border border-brand/20"
            >
              {value}
              <button
                type="button"
                phx-click="postures_remove_value"
                phx-value-id={@node.id}
                phx-value-value={value}
                class="hover:text-error transition-colors"
              >
                <.icon name="ri-close-line" class="w-2.5 h-2.5" />
              </button>
            </span>
            <input
              type="text"
              name={"_postures[#{@node.id}][value_input]"}
              value={@node.value_input}
              placeholder={value_placeholder(@type, @node.op)}
              phx-change="postures_change"
              phx-key="Enter"
              phx-keyup="postures_add_value"
              phx-value-id={@node.id}
              autocomplete="off"
              class={[@input_class, "flex-1 min-w-32 font-mono"]}
            />
            <button type="button" phx-click="postures_add_value" phx-value-id={@node.id} class={@small_button_class}>
              Add
            </button>
          </div>
        <% end %>
        <div
          :if={@node.provider != "firezone"}
          class="inline-flex rounded border border-border overflow-hidden"
          title="A provider can hold several records for one device"
        >
          <button
            type="button"
            phx-click="postures_set_rows"
            phx-value-id={@node.id}
            phx-value-rows="any"
            class={pill_class(@node.rows == "any")}
          >
            any record
          </button>
          <button
            type="button"
            phx-click="postures_set_rows"
            phx-value-id={@node.id}
            phx-value-rows="all"
            class={[pill_class(@node.rows == "all"), "border-l border-border"]}
          >
            all records
          </button>
        </div>
        <button
          type="button"
          phx-click="postures_remove"
          phx-value-id={@node.id}
          title="Remove rule"
          class="ml-auto flex items-center justify-center w-5 h-5 rounded text-subtle hover:text-heading hover:bg-raised transition-colors"
        >
          <.icon name="ri-close-line" class="w-3.5 h-3.5" />
        </button>
      </div>
      <p :if={@error} class="mt-1.5 text-xs text-error">{error_message(@error)}</p>
    </div>
    """
  end

  attr :node, :map, required: true
  attr :errors, :map, required: true

  def postures_check(assigns) do
    assigns =
      assigns
      |> assign(:error, Map.get(assigns.errors, assigns.node.id))
      |> assign(:select_class, [@input_class, "pr-8"])

    ~H"""
    <div
      id={"posture-node-#{@node.id}"}
      class={["rounded-lg border bg-surface px-2 py-2", if(@error, do: "border-error/60", else: "border-border")]}
    >
      <div class="flex items-center gap-1.5 flex-wrap">
        <.postures_not_toggle node={@node} />
        <span class="text-[10px] font-semibold tracking-wide uppercase text-subtle">Check</span>
        <select name={"_postures[#{@node.id}][check]"} phx-change="postures_change" class={@select_class}>
          <option :for={check <- Checks.all()} value={check.name} selected={check.name == @node.name}>
            {check.label}
          </option>
        </select>
        <button
          type="button"
          phx-click="postures_remove"
          phx-value-id={@node.id}
          title="Remove check"
          class="ml-auto flex items-center justify-center w-5 h-5 rounded text-subtle hover:text-heading hover:bg-raised transition-colors"
        >
          <.icon name="ri-close-line" class="w-3.5 h-3.5" />
        </button>
      </div>
      <p :if={@error} class="mt-1.5 text-xs text-error">{error_message(@error)}</p>
    </div>
    """
  end

  attr :node, :map, required: true

  def postures_not_toggle(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="postures_toggle_not"
      phx-value-id={@node.id}
      title={if @node.negated?, do: "Stop inverting", else: "Invert: hold when this does not match"}
      class={[
        "px-1.5 py-0.5 rounded text-[10px] font-semibold tracking-wide border transition-colors",
        if(@node.negated?,
          do: "bg-error text-white border-error",
          else: "bg-surface text-muted border-border hover:text-heading hover:border-border-emphasis"
        )
      ]}
    >
      NOT
    </button>
    """
  end

  attr :id, :string, required: true
  attr :state, :map, required: true

  def postures_json_editor(assigns) do
    {start, length} = (assigns.state.json_error && assigns.state.json_error.span) || {nil, nil}

    assigns =
      assigns
      |> assign(:error_start, start)
      |> assign(:error_length, length)
      |> assign(:editor_class, @editor_class)
      |> assign(:mark_class, @mark_class)

    ~H"""
    <div
      id={@id}
      phx-hook="PostureJsonEditor"
      data-error-start={@error_start}
      data-error-length={@error_length}
      data-validated-length={String.length(@state.json_text)}
      data-mark-class={@mark_class}
      class="relative"
    >
      <pre
        id={@id <> "-backdrop"}
        data-backdrop
        phx-update="ignore"
        aria-hidden="true"
        class={[@editor_class, "absolute inset-0 m-0 overflow-hidden pointer-events-none text-heading border border-transparent"]}
      ></pre>
      <textarea
        id={@id <> "-input"}
        name="_postures_json"
        rows="14"
        wrap="off"
        spellcheck="false"
        autocomplete="off"
        phx-change="postures_json_change"
        phx-debounce="400"
        placeholder={~s({"and": [{"field": "intune.compliance_state", "op": "is", "value": "compliant"}]})}
        class={[
          @editor_class,
          "relative block w-full resize-y overflow-auto rounded border bg-transparent text-transparent caret-heading placeholder:text-muted outline-none",
          "focus:ring-1 focus:ring-border-focus/30 transition-colors",
          if(@state.json_error, do: "border-error/60", else: "border-border focus:border-border-focus")
        ]}
      >{@state.json_text}</textarea>
    </div>
    <p :if={@state.json_error} class="mt-1.5 text-xs text-error">{error_message({nil, @state.json_error.message})}</p>
    <p class="mt-1.5 text-[10px] text-muted">
      A node is <code>and</code>, <code>or</code>, <code>not</code>, a named <code>check</code>, or a rule
      with <code>field</code> (<code>provider.field</code>), <code>op</code>, and <code>value</code>.
      Leave empty for no requirement.
    </p>
    """
  end

  attr :postures, :any, default: nil

  def postures_summary(assigns) do
    ~H"""
    <div :if={@postures} class="mt-4">
      <h4 class="text-[10px] font-semibold tracking-widest uppercase text-subtle mb-2">
        Device posture
      </h4>
      <div class="px-3 py-2.5 rounded border border-border bg-raised text-xs text-body">
        <.postures_summary_node node={Portal.Policies.Postures.to_map(@postures)} />
      </div>
    </div>
    """
  end

  attr :node, :map, required: true

  def postures_summary_node(%{node: %{"not" => inner}} = assigns) do
    assigns = assign(assigns, :inner, inner)

    ~H"""
    <div class="flex items-start gap-1.5">
      <span class="shrink-0 px-1 rounded text-[10px] font-semibold bg-error/10 text-error">NOT</span>
      <div class="flex-1 min-w-0"><.postures_summary_node node={@inner} /></div>
    </div>
    """
  end

  def postures_summary_node(%{node: %{"check" => name}} = assigns) do
    label =
      case Checks.fetch(name) do
        {:ok, check} -> check.label
        :error -> name
      end

    assigns = assign(assigns, :label, label)

    ~H"""
    <span>
      <span class="px-1 rounded text-[10px] font-semibold bg-brand-muted text-brand">check</span>
      {@label}
    </span>
    """
  end

  def postures_summary_node(%{node: %{"and" => nodes}} = assigns) do
    assigns = assign(assigns, nodes: nodes, label: "ALL of")
    postures_summary_group(assigns)
  end

  def postures_summary_node(%{node: %{"or" => nodes}} = assigns) do
    assigns = assign(assigns, nodes: nodes, label: "ANY of")
    postures_summary_group(assigns)
  end

  def postures_summary_node(assigns) do
    ~H"""
    <span class="font-mono break-all">
      {@node["field"]}
      <span class="text-subtle font-sans">{operator_label(@node["op"])}</span>
      {summary_value(@node["value"])}
      <span :if={@node["rows"] == "all"} class="text-subtle font-sans">(all records)</span>
    </span>
    """
  end

  defp postures_summary_group(assigns) do
    ~H"""
    <div>
      <span class="text-[10px] font-semibold text-subtle">{@label}</span>
      <ul class="ml-2 pl-2 border-l border-border space-y-1 mt-1">
        <li :for={node <- @nodes}><.postures_summary_node node={node} /></li>
      </ul>
    </div>
    """
  end

  defp summary_value(nil), do: ""
  defp summary_value(value) when is_list(value), do: Enum.map_join(value, ", ", &summary_value/1)
  defp summary_value(value) when is_binary(value), do: value
  defp summary_value(value), do: JSON.encode!(value)

  defp with_current(options, current) do
    if current in options or current in ["", nil] do
      options
    else
      options ++ [current]
    end
  end

  defp provider_label(provider), do: Map.get(@provider_labels, provider, provider)

  # Apple covers both of its operating systems with one icon.
  defp platform_icons(platforms) do
    apple = Enum.filter([:macos, :ios], &(&1 in platforms))

    [
      {:windows in platforms, {"ri-windows-fill", "Windows"}},
      {apple != [], {"ri-apple-fill", apple |> Enum.map(&platform_name/1) |> Enum.join(", ")}},
      {:android in platforms, {"ri-android-fill", "Android"}},
      {:linux in platforms, {"ri-ubuntu-fill", "Linux"}}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp platform_name(:macos), do: "macOS"
  defp platform_name(:ios), do: "iOS"

  defp operator_label(nil), do: ""
  defp operator_label(op), do: Map.get_lazy(@operator_labels, op, fn -> String.replace(op, "_", " ") end)

  defp value_placeholder(_type, op) when op in ~w[is_in is_not_in contains_any_of contains_all_of], do: "add a value"
  defp value_placeholder(:ipv6, _op), do: "fd00::/8"
  defp value_placeholder(_type, op) when op in ~w[is_in_cidr is_not_in_cidr], do: "10.0.0.0/8"
  defp value_placeholder(_type, op) when op in ~w[matches does_not_match], do: "^regex$"
  defp value_placeholder(:datetime, op) when op in ~w[within_last not_within_last], do: "PT24H"
  defp value_placeholder(:datetime, _op), do: "2026-01-01T00:00:00Z"
  defp value_placeholder(:version, _op), do: "14.4.1"
  defp value_placeholder(:integer, _op), do: "0"
  defp value_placeholder(:float, _op), do: "0.0"
  defp value_placeholder(_type, _op), do: "value"

  defp error_message({nil, message}), do: String.capitalize(String.first(message)) <> String.slice(message, 1..-1//1)
  defp error_message({sub, message}), do: String.capitalize(sub) <> " " <> message

  defp pill_class(active?) do
    [
      "px-2 py-0.5 text-[10px] transition-colors",
      if(active?, do: "bg-brand text-white", else: "bg-surface text-body hover:text-heading")
    ]
  end
end
