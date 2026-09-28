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

  @editor_class "font-mono text-xs leading-5 px-2 py-1.5 whitespace-pre"
  @mark_class "underline decoration-wavy decoration-error underline-offset-2 bg-error/10"

  attr :id, :string, required: true
  attr :account, :any, required: true
  attr :state, :map, required: true
  slot :inner_block, required: true

  def policy_restrictions(assigns) do
    assigns = assign(assigns, :conditions_enabled?, Portal.Account.policy_conditions_enabled?(assigns.account))

    ~H"""
    <div class="space-y-4">
      <%= if not @conditions_enabled? and @state.availability == :locked do %>
        <.upgrade_locked_section
          account={@account}
          message="Upgrade your plan to unlock policy conditions and device posture checks."
          description="Restrict access by location, identity, time, and device security."
          data-locked-section="policy-restrictions"
        >
          <.conditions_preview />
          <div class="mt-4 border-t border-border pt-4">
            <h4 class="mb-3 text-[10px] font-semibold tracking-widest uppercase text-subtle">Device posture</h4>
            <.postures_preview />
          </div>
        </.upgrade_locked_section>
      <% else %>
        {render_slot(@inner_block)}
        <.postures_section id={@id} account={@account} state={@state} />
      <% end %>
    </div>
    """
  end

  def conditions_preview(assigns) do
    ~H"""
    <div aria-hidden="true">
      <h4 class="mb-3 text-[10px] font-semibold tracking-widest uppercase text-subtle">Conditions</h4>
      <div class="space-y-2">
        <div :for={{label, value} <- [{"Location", "Allowed countries"}, {"IP range", "10.0.0.0/8"}, {"Time of day", "Monday – Friday, 9:00 – 17:00"}]} class="flex justify-between rounded-lg border border-border bg-raised p-3 text-xs">
          <span class="font-medium text-body">{label}</span>
          <span class="text-subtle">{value}</span>
        </div>
      </div>
    </div>
    """
  end

  def postures_preview(assigns) do
    ~H"""
    <div aria-hidden="true" class="min-h-52 rounded-lg border border-border overflow-hidden">
      <div class="bg-raised px-3 py-2 text-[10px] font-semibold uppercase tracking-widest text-subtle">Device checks</div>
      <div :for={label <- ["Client is up to date", "Disk encryption enabled", "Device is compliant", "Endpoint protection enabled"]} class="flex items-center justify-between border-t border-border px-3 py-3 text-xs text-body">
        <span>{label}</span>
        <.icon name="ri-checkbox-circle-line" class="h-4 w-4 text-subtle" />
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :account, :any, required: true
  attr :state, :map, required: true
  def postures_section(assigns) do
    ~H"""
    <div id={@id} class="border-t border-border pt-4">
      <div class="flex items-center justify-between gap-2 mb-3">
        <div class="flex items-center gap-2">
          <h4 class="text-[10px] font-semibold tracking-widest uppercase text-subtle">
            Device posture
          </h4>
          <.new_badge data-postures-new-badge />
          <span class="text-[10px] text-muted">
            (optional)
          </span>
        </div>
        <div :if={@state.availability == :enabled} class="flex items-center gap-2">
          <button
            :if={Postures.dirty?(@state)}
            type="button"
            phx-click="postures_reset"
            class="flex items-center gap-1 text-[10px] text-body hover:text-heading transition-colors"
            title="Back to the saved rules"
          >
            <.icon name="ri-arrow-go-back-line" class="w-3 h-3" /> Reset
          </button>
          <div class="inline-flex rounded border border-border overflow-hidden">
            <button type="button" phx-click="postures_tab" phx-value-tab="simple" class={pill_class(@state.tab == :simple)}>
              Simplified
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
      </div>
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
          <.postures_preview />
        </.upgrade_locked_section>
      <% else %>
        <input type="hidden" name="policy[postures]" value={Postures.hidden_value(@state)} />
        <.postures_checks :if={@state.tab == :simple} id={@id <> "-checks"} state={@state} />
        <.postures_json_editor :if={@state.tab == :json} id={@id <> "-json"} state={@state} />
      <% end %>
      <p :if={@state.availability == :enabled} class="mt-2 text-xs text-subtle">
        Check the <.website_link path="/kb/device-posture/grammar">grammar reference</.website_link> to configure over 300 posture fields.
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
        This policy has posture rules these checks cannot show. Edit them in the JSON tab; saving from
        here keeps them as they are.
      </p>
      <p :if={not @custom? and @state.json_error} class="px-3 py-2 text-xs text-warning border-b border-border bg-raised">
        The JSON tab holds an error. These are the last rules that were valid.
      </p>
      <table class="w-full text-sm text-body">
        <thead class="bg-raised text-[10px] font-semibold tracking-widest uppercase text-subtle">
          <tr>
            <th class="pl-3 py-2 w-8"></th>
            <th class="px-3 py-2 text-left">Check</th>
            <th class="px-3 py-2 w-14"></th>
          </tr>
        </thead>
        <tbody class="divide-y divide-border bg-surface">
          <tr :for={check <- Checks.all()}>
            <td class="pl-3 py-2.5 align-middle">
              <.popover placement="right" class="flex">
                <:target>
                  <.icon name="ri-information-line" class="w-4 h-4 text-subtle hover:text-heading cursor-help" />
                </:target>
                <:content>
                  <.check_support check={check} />
                </:content>
              </.popover>
            </td>
            <td class="px-3 py-2.5 align-middle">
              <div class="text-xs font-semibold text-body">{check.label}</div>
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
    <p :if={@state.json_error} data-postures-json-error class="mt-1.5 text-xs text-error">
      {error_message(@state.json_error.message)}
    </p>
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

  def postures_summary(%{postures: nil} = assigns), do: ~H""

  def postures_summary(assigns) do
    state = Postures.new(:enabled, assigns.postures)
    wire = state.wire

    checks =
      case Postures.checks(state) do
        {:ok, names} -> Enum.map(names, &check!/1)
        :custom -> :custom
      end

    assigns = assign(assigns, wire: wire, checks: checks)

    ~H"""
    <div class="mt-4">
      <%= if @checks == :custom do %>
        <.json_view id="policy-postures-rules" value={@wire} label="Device posture" hint="Custom rules" collapsed />
      <% else %>
        <h4 class="text-[10px] font-semibold tracking-widest uppercase text-subtle mb-2">
          Device posture
        </h4>
        <ul class="rounded border border-border bg-raised divide-y divide-border">
          <li :for={check <- @checks} class="flex items-center gap-2 px-3 py-2">
            <.icon name="ri-checkbox-circle-fill" class="w-3.5 h-3.5 shrink-0 text-success" />
            <span class="text-xs font-medium text-heading">{check.label}</span>
            <span class="text-xs text-subtle truncate">{check.description}</span>
          </li>
        </ul>
      <% end %>
    </div>
    """
  end

  defp check!(name) do
    {:ok, check} = Checks.fetch(name)
    check
  end

  defp toggle_title(state, check, enabled) do
    if check.name in enabled or Postures.check_available?(state, check) do
      nil
    else
      "Connect #{Enum.map_join(check.providers, " or ", &provider_label(Atom.to_string(&1)))} to use this check."
    end
  end

  defp provider_label(provider), do: Map.get(@provider_labels, provider, provider)

  defp error_message(message), do: String.capitalize(String.first(message)) <> String.slice(message, 1..-1//1)

  defp pill_class(active?) do
    [
      "px-2 py-0.5 text-[10px] transition-colors",
      if(active?, do: "bg-brand text-white", else: "bg-surface text-body hover:text-heading")
    ]
  end

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
