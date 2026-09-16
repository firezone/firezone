defmodule PortalWeb.Policies.PostureComponents do
  use PortalWeb, :component_library
  alias PortalWeb.Policies.Postures
  alias PortalWeb.Policies.Postures.Checks

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
  def postures_section(assigns) do
    ~H"""
    <div :if={@state.availability != :hidden} id={@id} class="border-t border-border pt-4">
      <h4 class="text-[10px] font-semibold tracking-widest uppercase text-subtle mb-3">
        Device posture
        <span
          data-postures-new-badge
          class="ml-1.5 px-1 py-px rounded text-[9px] font-semibold tracking-wider normal-case bg-brand-muted text-brand"
        >
          NEW
        </span>
        <span class="ml-1 font-normal normal-case tracking-normal text-muted">
          (optional)
        </span>
      </h4>
      <div
        :if={@state.availability == :enabled and not @state.trust_anchors?}
        class="mb-3 flex items-start gap-1.5 rounded border border-warning-light bg-warning-light px-3 py-2 text-xs text-warning"
      >
        <.icon name="ri-error-warning-line" class="w-3.5 h-3.5 shrink-0 mt-0.5" />
        <span>
          No
          <.link navigate={~p"/#{@account}/settings/trust_anchors"} class="font-medium underline hover:no-underline">
            trust anchors
          </.link>
          are defined. Devices will be identified by Firezone-reported attributes only.
          <.website_link path="/kb/device-trust" fragment="device-attributes" class="font-medium underline hover:no-underline">
            Learn more
          </.website_link>
        </span>
      </div>
      <%= if @state.availability == :locked do %>
        <.upgrade_locked_section
          account={@account}
          message="Upgrade your plan to unlock device posture checks."
          description="Require devices to pass MDM and EDR checks before access is granted."
          data-locked-section="device-posture"
        >
          <p class="text-xs text-body text-center py-4 rounded-lg border border-dashed border-border">
            No posture checks — any device is allowed
          </p>
        </.upgrade_locked_section>
      <% else %>
        <input type="hidden" name="policy[postures]" value={Postures.hidden_value(@state)} />
        <.postures_checks id={@id <> "-checks"} state={@state} />
      <% end %>
      <p class="mt-2 text-xs text-subtle">
        Over <.website_link path="/kb/device-posture">300 more device posture fields</.website_link> are available to configure through the REST API.
      </p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :state, :map, required: true

  def postures_checks(assigns) do
    {enabled, custom?} =
      case Postures.checks(assigns.state) do
        {:ok, names} -> {names, false}
        :custom -> {[], true}
      end

    assigns = assign(assigns, enabled: enabled, custom?: custom?)

    ~H"""
    <div id={@id} class="rounded-lg border border-border overflow-hidden">
      <p :if={@custom?} class="px-3 py-2 text-xs text-warning border-b border-border bg-raised">
        This policy has posture rules written through the REST API that these checks cannot show.
        Saving keeps them as they are.
      </p>
      <table class="w-full text-sm text-body">
        <thead class="bg-raised text-[10px] font-semibold tracking-widest uppercase text-subtle">
          <tr>
            <th class="px-3 py-2 text-left">Check</th>
            <th class="px-3 py-2 w-14"></th>
          </tr>
        </thead>
        <tbody class="divide-y divide-border bg-surface">
          <tr :for={check <- Checks.all()}>
            <td class="px-3 py-2.5 align-middle">
              <div class="flex items-center gap-1.5">
                <span class="text-xs font-semibold text-body">{check.label}</span>
                <.popover placement="right" class="inline-flex">
                  <:target>
                    <.icon name="ri-information-line" class="w-3.5 h-3.5 text-subtle hover:text-heading cursor-help" />
                  </:target>
                  <:content>
                    <.check_support check={check} />
                  </:content>
                </.popover>
              </div>
              <div class="text-xs text-subtle mt-0.5">{check.description}</div>
            </td>
            <td class="px-3 py-2.5 align-middle">
              <span class="flex justify-end" title={toggle_title(@state, check, @enabled)}>
                <.toggle
                  id={"#{@id}-#{check.name}"}
                  checked={check.name in @enabled}
                  disabled={@custom? or (check.name not in @enabled and not Postures.check_available?(@state, check))}
                  phx-click="postures_toggle_check"
                  phx-value-name={check.name}
                />
              </span>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :check, :map, required: true

  defp check_support(assigns) do
    ~H"""
    <dl class="space-y-2 min-w-44">
      <div>
        <dt class="text-[10px] font-semibold tracking-widest uppercase text-subtle mb-1">Supported providers</dt>
        <dd class="space-y-1">
          <div :for={provider <- @check.providers} class="flex items-center gap-2">
            <span class="w-5 shrink-0 flex justify-center">
              <.provider_icon provider={Atom.to_string(provider)} size="sm" />
            </span>
            <span>{provider_label(Atom.to_string(provider))}</span>
          </div>
        </dd>
      </div>
      <div>
        <dt class="text-[10px] font-semibold tracking-widest uppercase text-subtle mb-1">Supported platforms</dt>
        <dd class="space-y-1">
          <div :for={{icon, title} <- platform_icons(@check.platforms)} class="flex items-center gap-2">
            <span class="w-5 shrink-0 flex justify-center">
              <.icon name={icon} class="w-4 h-4" />
            </span>
            <span>{title}</span>
          </div>
        </dd>
      </div>
    </dl>
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

  defp toggle_title(state, check, enabled) do
    if check.name in enabled or Postures.check_available?(state, check) do
      nil
    else
      "Connect #{Enum.map_join(check.providers, " or ", &provider_label(Atom.to_string(&1)))} to use this check."
    end
  end

  defp provider_label(provider), do: Map.get(@provider_labels, provider, provider)

  defp operator_label(nil), do: ""
  defp operator_label(op), do: Map.get_lazy(@operator_labels, op, fn -> String.replace(op, "_", " ") end)

  @platform_icons [
    windows: {"icon-os-windows", "Windows"},
    macos: {"icon-os-macos", "macOS"},
    ios: {"icon-os-ios", "iOS"},
    android: {"icon-os-android", "Android"},
    linux: {"icon-os-linux", "Linux"}
  ]

  defp platform_icons(platforms) do
    for {platform, icon} <- @platform_icons, platform in platforms, do: icon
  end
end
