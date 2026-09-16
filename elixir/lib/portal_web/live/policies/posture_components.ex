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
  attr :mode, :atom, default: :new

  def postures_section(assigns) do
    ~H"""
    <div :if={@state.availability != :hidden} id={@id} class="border-t border-border pt-4">
      <h4 class="text-[10px] font-semibold tracking-widest uppercase text-subtle mb-1">
        Device posture
        <span class="ml-1 font-normal normal-case tracking-normal text-muted">
          (optional)
        </span>
      </h4>
      <p class="mb-3 text-xs text-body">
        Turn on the checks a device must pass. Over 300 more posture fields are available through the
        <.website_link path="/kb/device-posture">REST API</.website_link>.
      </p>
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
          <p class="text-xs text-body text-center py-4 rounded-lg border border-dashed border-border">
            No posture checks — any device is allowed
          </p>
        </.upgrade_locked_section>
      <% else %>
        <input type="hidden" name="policy[postures]" value={Postures.hidden_value(@state)} />
        <.postures_checks id={@id <> "-checks"} state={@state} />
      <% end %>
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
      <table class="w-full text-xs">
        <thead class="bg-raised text-[10px] font-semibold tracking-widest uppercase text-subtle">
          <tr>
            <th class="px-3 py-2 text-left w-12"></th>
            <th class="px-3 py-2 text-left">Check</th>
            <th class="px-3 py-2 text-left w-28">Providers</th>
            <th class="px-3 py-2 text-left w-28">Platforms</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-border bg-surface">
          <tr :for={check <- Checks.all()}>
            <td class="px-3 py-2.5 align-top">
              <.toggle
                id={"#{@id}-#{check.name}"}
                size="sm"
                checked={check.name in @enabled}
                disabled={@custom? or not Postures.check_available?(@state, check)}
                phx-click="postures_toggle_check"
                phx-value-name={check.name}
              />
            </td>
            <td class="px-3 py-2.5">
              <div class="text-xs font-medium text-heading">{check.label}</div>
              <div class="text-xs text-body">{check.description}</div>
              <div :if={not Postures.check_available?(@state, check)} class="text-xs text-subtle mt-0.5">
                Connect {check.providers |> Enum.map(&provider_label(Atom.to_string(&1))) |> Enum.join(" or ")} to use this check.
              </div>
            </td>
            <td class="px-3 py-2.5 align-top">
              <div class="flex items-center gap-1.5">
                <.provider_icon
                  :for={provider <- check.providers}
                  provider={Atom.to_string(provider)}
                  size="xs"
                  title={provider_label(Atom.to_string(provider))}
                />
              </div>
            </td>
            <td class="px-3 py-2.5 align-top">
              <div class="flex items-center gap-1.5 text-heading">
                <.icon :for={{icon, title} <- platform_icons(check.platforms)} name={icon} title={title} class="w-3.5 h-3.5" />
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
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

  defp provider_label(provider), do: Map.get(@provider_labels, provider, provider)

  defp operator_label(nil), do: ""
  defp operator_label(op), do: Map.get_lazy(@operator_labels, op, fn -> String.replace(op, "_", " ") end)

  # Apple covers both of its operating systems with one icon.
  defp platform_icons(platforms) do
    apple = Enum.filter([:macos, :ios], &(&1 in platforms))

    [
      {:windows in platforms, {"ri-windows-fill", "Windows"}},
      {apple != [], {"ri-apple-fill", Enum.map_join(apple, ", ", &platform_name/1)}},
      {:android in platforms, {"ri-android-fill", "Android"}},
      {:linux in platforms, {"ri-ubuntu-fill", "Linux"}}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp platform_name(:macos), do: "macOS"
  defp platform_name(:ios), do: "iOS"
end
