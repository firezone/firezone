defmodule PortalWeb.GettingStarted do
  @moduledoc """
  The getting started guide new account owners see when they first sign in.

  It lives in the sidebar, as a "Getting started" entry with the progress of the
  goal being worked on, and as the modal that entry opens. The modal opens by itself
  once, on a chooser asking what the admin wants to do first. The entry (and the one
  in the user menu, which sends `"open"` to `#getting-started`) stays until the admin
  finishes a goal or chooses to explore on their own. Where they are is kept in the
  actor's preferences, see `Portal.Actor.Preferences`.

  Each goal is a few steps, most of them finished by something happening outside the
  portal:

    * "Connect my devices": this computer signs in, a second one signs in, and the
      first reaches the second through the `My devices` pool.
    * "Reach a remote network or service": this computer signs in, the admin enters
      an address (which becomes a Resource in the Default Site that Everyone may
      reach), a Gateway connects to that Site, and this computer reaches the Resource.

  A component can't receive messages, so while a step is waiting the guide checks
  again every `:poll_interval_ms` (2 seconds by default) with `send_update_after/3`.
  Presence is read from memory; the database is only asked about devices it hasn't
  seen yet and, on the last step, whether the connection has happened.

  The guide always opens on the first step that isn't done yet, judged by what
  exists rather than by where the modal was left.
  """
  use PortalWeb, :live_component

  alias __MODULE__.Database
  alias Portal.Presence
  alias PortalWeb.Sites.Components, as: SiteComponents

  @goals %{"device_mesh" => :device_mesh, "remote_access" => :remote_access}
  @flows Map.values(@goals)

  # The states in which the guide is still offered in the sidebar and user menu
  @offered [:pending, :closed | @flows]

  @deploy_tabs [
    {"debian", "Debian/Ubuntu", "icon-os-debian"},
    {"docker", "Docker", "icon-docker"},
    {"systemd", "systemd", "ri-terminal-line"}
  ]
  @deploy_tab_values Enum.map(@deploy_tabs, &elem(&1, 0))

  @client_tabs [
    {"macos", "macOS", "ri-apple-line"},
    {"windows", "Windows", "ri-windows-line"},
    {"linux", "Linux", "ri-ubuntu-line"}
  ]
  @client_tab_values Enum.map(@client_tabs, &elem(&1, 0))

  @doc "Whether the guide is still offered to the actor in the sidebar and user menu."
  @spec offered?(Portal.Actor.t()) :: boolean()
  def offered?(actor), do: actor |> preference(:getting_started) |> offered_state?()

  defp offered_state?(state), do: state in @offered

  @impl true
  def update(%{poll: ref}, socket) do
    if ref == socket.assigns.poll_ref and polling?(socket) do
      {:ok, socket |> refresh() |> schedule_poll()}
    else
      {:ok, socket}
    end
  end

  def update(assigns, socket) do
    {:ok, socket |> assign(subject: assigns.subject) |> assign_initial_state()}
  end

  # The subject the layout passes in is not refreshed after we save, so it is only
  # read once. Otherwise every re-render of the page would reopen the modal. Saves
  # go through the `actor` kept here, which is replaced by each save's result, as
  # the preferences are written whole.
  defp assign_initial_state(%{assigns: %{pending?: _}} = socket), do: socket

  defp assign_initial_state(socket) do
    %{actor: actor, context: context} = socket.assigns.subject
    pending? = pending?(actor)

    socket
    |> assign(
      actor: actor,
      pending?: pending?,
      open?: pending?,
      goal: preference(actor, :getting_started),
      view: :chooser,
      step: 0,
      poll_ref: nil,
      devices: [],
      connected?: false,
      resource: nil,
      address_form: address_form(),
      gateway_env: nil,
      deploy_tab: "debian",
      client_tab: client_tab(context.user_agent),
      gateway_online?: false,
      reached?: false
    )
    |> load_progress()
  end

  # Works out how far along the picked goal is, for the sidebar's progress bar.
  defp load_progress(%{assigns: %{goal: goal}} = socket) when goal in @flows, do: start(socket, goal)
  defp load_progress(socket), do: socket

  @impl true
  def render(assigns) do
    ~H"""
    <div id="getting-started" class={offered_state?(@goal) && "border-t border-border py-2 px-2 shrink-0"}>
      <.sidebar_entry
        :if={offered_state?(@goal)}
        progress={progress(assigns)}
        target={@myself}
      />

      <Form.modal :if={@open?} id="getting-started-modal" on_close="dismiss" target={@myself}>
        <:title>{title(@view, @subject.actor)}</:title>
        <:body>
          <.chooser :if={@view == :chooser} target={@myself} />
          <.mesh
            :if={@view == :device_mesh}
            step={@step}
            devices={@devices}
            connected?={@connected?}
            account={@subject.account}
            client_tab={@client_tab}
            target={@myself}
          />
          <.remote
            :if={@view == :remote_access}
            step={@step}
            devices={@devices}
            resource={@resource}
            address_form={@address_form}
            gateway_env={@gateway_env}
            deploy_tab={@deploy_tab}
            gateway_online?={@gateway_online?}
            reached?={@reached?}
            account={@subject.account}
            client_tab={@client_tab}
            target={@myself}
          />
        </:body>
        <:footer :if={@view != :chooser}>
          <.footer
            view={@view}
            step={@step}
            done?={step_done?(assigns, @step)}
            submit_address?={@view == :remote_access and @step == 1 and is_nil(@resource)}
            target={@myself}
          />
        </:footer>
      </Form.modal>
    </div>
    """
  end

  # ── Sidebar ─────────────────────────────────────────────────────────────────

  attr :progress, :any, required: true
  attr :target, :any, required: true

  defp sidebar_entry(assigns) do
    ~H"""
    <button
      id="getting-started-sidebar"
      type="button"
      phx-click="open"
      phx-target={@target}
      data-sidebar-nav-item
      title="Getting started"
      class="w-full px-2 py-1.5 rounded text-left text-sm text-body hover:text-heading hover:bg-raised transition-colors"
    >
      <span class="flex items-center gap-2.5">
        <Core.icon name="ri-rocket-2-line" class="w-4 h-4 shrink-0 text-brand" />
        <span
          data-sidebar-label
          class="whitespace-nowrap transition-[max-width,opacity] duration-200 max-w-xs opacity-100 flex-1"
        >
          Getting started
        </span>
        <span
          :if={@progress}
          id="getting-started-sidebar-count"
          data-sidebar-label
          class="text-xs text-subtle tabular-nums"
        >
          {elem(@progress, 0)}/{elem(@progress, 1)}
        </span>
      </span>
      <span
        :if={@progress}
        data-sidebar-label
        class="flex gap-0.5 mt-1.5 ml-6.5"
        aria-hidden="true"
      >
        <span
          :for={i <- 1..elem(@progress, 1)}
          class={[
            "flex-1 h-1 rounded-full",
            if(i <= elem(@progress, 0), do: "bg-brand", else: "bg-border-strong")
          ]}
        >
        </span>
      </span>
    </button>
    """
  end

  defp progress(%{view: view} = assigns) when view in @flows do
    total = total_steps(view)
    {done_count(view, total - 1, assigns), total}
  end

  defp progress(_assigns), do: nil

  # ── Chooser ─────────────────────────────────────────────────────────────────

  attr :target, :any, required: true

  defp chooser(assigns) do
    ~H"""
    <p class="text-base font-semibold text-heading">What would you like to do first?</p>
    <p class="mt-1 text-sm text-subtle">
      Pick one for a quick, guided setup. You can always do the other later.
    </p>

    <div class="mt-5 grid auto-rows-fr gap-3">
      <.goal
        goal="device_mesh"
        icon="ri-share-line"
        icon_class="bg-brand-subtle text-brand-strong"
        title="Connect my devices"
        steps={3}
        minutes={3}
        target={@target}
      >
        Link your computers into a private network so they can reach each other from anywhere.
      </.goal>
      <.goal
        goal="remote_access"
        icon="ri-building-line"
        icon_class="bg-accent-wash text-accent-strong"
        title="Reach a remote network or service"
        steps={4}
        minutes={5}
        target={@target}
      >
        Securely access a private app, server or network, for yourself or your team.
      </.goal>
    </div>

    <div class="mt-4 text-center">
      <button
        id="getting-started-explore"
        type="button"
        phx-click="explore"
        phx-target={@target}
        class="px-3 py-1.5 rounded text-sm text-subtle hover:text-heading hover:bg-raised transition-colors"
      >
        I'll explore on my own
      </button>
    </div>
    """
  end

  attr :goal, :string, required: true
  attr :icon, :string, required: true
  attr :icon_class, :string, required: true
  attr :title, :string, required: true
  attr :steps, :integer, required: true
  attr :minutes, :integer, required: true
  attr :target, :any, required: true
  slot :inner_block, required: true

  defp goal(assigns) do
    ~H"""
    <button
      id={"getting-started-goal-#{@goal}"}
      type="button"
      phx-click="choose"
      phx-value-goal={@goal}
      phx-target={@target}
      class={[
        "group flex items-center gap-4 w-full h-full px-4 py-3.5 text-left",
        "rounded-lg border border-border-strong bg-surface",
        "hover:border-brand hover:bg-brand-muted transition-colors"
      ]}
    >
      <div class={["shrink-0 w-10 h-10 rounded-lg flex items-center justify-center", @icon_class]}>
        <Core.icon name={@icon} class="w-5 h-5" />
      </div>
      <div class="flex-1 min-w-0">
        <p class="text-sm font-semibold text-heading">{@title}</p>
        <p class="mt-0.5 text-xs text-subtle">{render_slot(@inner_block)}</p>
        <p class="mt-1.5 flex items-center gap-3 text-xs text-subtle">
          <span class="inline-flex items-center gap-1">
            <Core.icon name="ri-list-check-2" class="w-3.5 h-3.5" />{@steps} steps
          </span>
          <span class="inline-flex items-center gap-1">
            <Core.icon name="ri-time-line" class="w-3.5 h-3.5" />~{@minutes} min
          </span>
        </p>
      </div>
      <Core.icon
        name="ri-arrow-right-line"
        class="shrink-0 w-5 h-5 text-subtle group-hover:text-brand transition-colors"
      />
    </button>
    """
  end

  # ── Connect my devices ──────────────────────────────────────────────────────

  attr :step, :integer, required: true
  attr :devices, :list, required: true
  attr :connected?, :boolean, required: true
  attr :account, :any, required: true
  attr :client_tab, :string, required: true
  attr :target, :any, required: true

  defp mesh(assigns) do
    assigns =
      assign(assigns,
        first: Enum.at(assigns.devices, 0),
        second: Enum.at(assigns.devices, 1),
        done: done_count(:device_mesh, assigns.step, assigns)
      )

    ~H"""
    <div id="getting-started-mesh" class="min-h-96">
      <.stepper :if={@step < 3} step={@step} total={3} done={@done} />

      <div :if={@step == 0} id="getting-started-mesh-step-0">
        <.install_this_computer
          account={@account}
          first={@first}
          client_tab={@client_tab}
          target={@target}
        />
      </div>

      <div :if={@step == 1} id="getting-started-mesh-step-1">
        <h4 class="text-base font-semibold text-heading">Install Firezone on another computer</h4>
        <p class="mt-1 mb-4 text-sm text-body">
          On a second computer, install Firezone and sign in to the same account.
        </p>
        <.client_install account={@account} client_tab={@client_tab} target={@target} />
        <.live_status
          id="getting-started-status-1"
          done?={@second != nil}
          waiting="Waiting for a second computer…"
          waiting_hint="Keep this window open. It updates as soon as it connects."
          done={@second && "#{@second.name} is online"}
          done_hint={@second && "Reachable at #{@second.fqdn}"}
        />
      </div>

      <div :if={@step == 2 and @second} id="getting-started-mesh-step-2">
        <h4 class="text-base font-semibold text-heading">
          Ping {@second.name} from {@first.name}
        </h4>
        <p class="mt-1 mb-4 text-sm text-body">
          Open a terminal on <span class="font-medium text-heading">{@first.name}</span> and run:
        </p>
        <Core.code_block id="getting-started-ping" class="mb-4 rounded">ping {@second.fqdn}</Core.code_block>
        <.live_status
          id="getting-started-status-2"
          done?={@connected?}
          waiting="Waiting for your ping…"
          waiting_hint="Works from anywhere, not just your home network."
          done={"#{@first.name} reached #{@second.name}"}
          done_hint="Your devices can reach each other."
        />
      </div>

      <div :if={@step == 3} id="getting-started-mesh-done">
        <.finished title="Your devices are connected">
          <:lead :if={@second}>
            <span class="font-medium text-heading">{@first.name}</span>
            reached <span class="font-medium text-heading">{@second.name}</span>
            over an encrypted tunnel. Any device you sign in on joins the same network.
          </:lead>
          <:link website="/kb/client-apps" icon="ri-device-line">
            Install Firezone on more devices
          </:link>
          <:link website="/kb/administer/troubleshooting" icon="ri-tools-line">
            Troubleshooting
          </:link>
        </.finished>
      </div>
    </div>
    """
  end

  # ── Reach a remote network or service ───────────────────────────────────────

  attr :step, :integer, required: true
  attr :devices, :list, required: true
  attr :resource, :any, required: true
  attr :address_form, :any, required: true
  attr :gateway_env, :any, required: true
  attr :deploy_tab, :string, required: true
  attr :gateway_online?, :boolean, required: true
  attr :reached?, :boolean, required: true
  attr :account, :any, required: true
  attr :client_tab, :string, required: true
  attr :target, :any, required: true

  defp remote(assigns) do
    {try_heading, try_command} = if assigns.resource, do: try_it(assigns.resource), else: {nil, nil}

    assigns =
      assign(assigns,
        first: Enum.at(assigns.devices, 0),
        done: done_count(:remote_access, assigns.step, assigns),
        address_type: address_type(assigns.address_form[:address].value),
        try_heading: try_heading,
        try_command: try_command
      )

    ~H"""
    <div id="getting-started-remote" class="min-h-96">
      <.stepper :if={@step < 4} step={@step} total={4} done={@done} />

      <div :if={@step == 0} id="getting-started-remote-step-0">
        <.install_this_computer
          account={@account}
          first={@first}
          client_tab={@client_tab}
          target={@target}
          lead="You'll use it to test access at the end."
        />
      </div>

      <div :if={@step == 1} id="getting-started-remote-step-1">
        <h4 class="text-base font-semibold text-heading">What do you want to reach?</h4>
        <p class="mt-1 mb-4 text-sm text-body">
          Enter the address of a private app or network, as you'd type it at the office.
        </p>
        <.form
          :if={is_nil(@resource)}
          for={@address_form}
          id="getting-started-address-form"
          phx-change="validate_address"
          phx-submit="save_address"
          phx-target={@target}
        >
          <div class="flex items-start gap-2">
            <div class="flex-1">
              <Form.input
                field={@address_form[:address]}
                placeholder="wiki.example.internal"
                autocomplete="off"
                spellcheck="false"
                phx-debounce="200"
                class="font-mono"
                required
              />
            </div>
            <span
              :if={@address_type}
              id="getting-started-address-type"
              class="shrink-0 mt-2 px-2 py-1 rounded text-xs font-medium bg-badge-dns text-badge-dns-text"
            >
              {@address_type |> Atom.to_string() |> String.upcase()}
            </span>
          </div>
          <p class="mt-3 flex items-center flex-wrap gap-1.5 text-xs text-subtle">
            Examples:
            <button
              :for={example <- ~w[wiki.example.internal 10.0.1.20 10.0.0.0/16]}
              type="button"
              phx-click="example_address"
              phx-value-address={example}
              phx-target={@target}
              class="px-2 py-0.5 rounded-full border border-border-strong font-mono text-body hover:border-brand hover:text-heading"
            >
              {example}
            </button>
          </p>
          <p class="mt-4 flex gap-1.5 text-xs text-subtle">
            <Core.icon name="ri-information-line" class="shrink-0 w-4 h-4" />
            We'll add it to your Default Site and let everyone in your account reach it.
            You can change both later.
          </p>
        </.form>
        <.live_status
          :if={@resource}
          id="getting-started-status-resource"
          done?={true}
          waiting=""
          waiting_hint=""
          done={"#{@resource.address} was added"}
          done_hint="It's in your Default Site, and everyone in your account can reach it."
        />
      </div>

      <div :if={@step == 2 and @resource} id="getting-started-remote-step-2">
        <h4 class="text-base font-semibold text-heading">Install a Gateway</h4>
        <p class="mt-1 mb-4 text-sm text-body">
          Run this on a Linux machine that can already reach
          <span class="font-medium text-heading">{@resource.address}</span>.
          It only makes outbound connections, so you don't need to open firewall ports.
        </p>
        <.gateway_install
          :if={@gateway_env}
          deploy_tab={@deploy_tab}
          gateway_env={@gateway_env}
          target={@target}
        />
        <.live_status
          id="getting-started-status-gateway"
          done?={@gateway_online?}
          waiting="Waiting for your Gateway to connect…"
          waiting_hint="Usually under a minute after the command finishes."
          done="Your Gateway is online"
          done_hint={"It's ready to forward traffic to #{@resource.address}."}
        />
      </div>

      <div :if={@step == 3 and @resource} id="getting-started-remote-step-3">
        <h4 class="text-base font-semibold text-heading">{@try_heading}</h4>
        <p class="mt-1 mb-4 text-sm text-body">
          From <span class="font-medium text-heading">{if @first, do: @first.name, else: "this computer"}</span>,
          connect to it the way you normally would{if @try_command, do: ". For example:", else: "."}
        </p>
        <Core.code_block :if={@try_command} id="getting-started-try" class="mb-4 rounded">{@try_command}</Core.code_block>
        <.live_status
          id="getting-started-status-reach"
          done?={@reached?}
          waiting="Waiting for your first connection…"
          waiting_hint="We'll see it as soon as you try, even if nothing answers."
          done={"Connected to #{@resource.address}"}
          done_hint="Firezone is protecting it."
        />
      </div>

      <div :if={@step == 4 and @resource} id="getting-started-remote-done">
        <.finished title="You're connected">
          <:lead>
            You reached <span class="font-medium text-heading">{@resource.address}</span>
            through your Gateway. Everyone in your account can now do the same.
          </:lead>
          <:link navigate={~p"/#{@account}/actors"} icon="ri-user-add-line">
            Add the people on your team
          </:link>
          <:link navigate={~p"/#{@account}/groups/new"} icon="ri-team-line">
            Create groups for your team
          </:link>
          <:link navigate={~p"/#{@account}/resources/#{@resource.id}"} icon="ri-shield-line">
            Choose which groups can access it
          </:link>
          <:link navigate={~p"/#{@account}/resources"} icon="ri-server-line">
            Add more Resources
          </:link>
        </.finished>
      </div>
    </div>
    """
  end

  attr :deploy_tab, :string, required: true
  attr :gateway_env, :list, required: true
  attr :target, :any, required: true

  # Each method in as few steps as it allows. The Debian package asks for the token
  # interactively, so connecting it is its own line: pasted together with the
  # install commands, the lines after it would be read as the token.
  defp gateway_install(assigns) do
    assigns = assign(assigns, tabs: @deploy_tabs)

    ~H"""
    <div class="mb-4">
      <.tabs id="getting-started-gateway-tabs" tabs={@tabs} selected={@deploy_tab} event="deploy_tab" target={@target} />

      <div :if={@deploy_tab == "debian"} class="space-y-2">
        <p class="text-xs text-body">1. Install the Gateway:</p>
        <Core.code_block
          id="getting-started-gateway-debian-install"
          class="text-xs rounded"
        >{SiteComponents.gateway_debian_install_commands() |> String.trim()}</Core.code_block>
        <p class="pt-1 text-xs text-body">2. Connect it, and paste this token when asked:</p>
        <Core.code_block
          id="getting-started-gateway-debian-connect"
          class="text-xs rounded"
        >sudo firezone-gateway authenticate && sudo firezone-gateway enable-service</Core.code_block>
        <Core.code_block
          id="getting-started-gateway-debian-token"
          class="text-xs rounded"
        >{SiteComponents.gateway_token(@gateway_env)}</Core.code_block>
      </div>

      <div :if={@deploy_tab == "docker"}>
        <Core.code_block
          id="getting-started-gateway-docker"
          class="text-xs rounded"
        >{SiteComponents.gateway_docker_command(@gateway_env)}</Core.code_block>
      </div>

      <div :if={@deploy_tab == "systemd"}>
        <Core.code_block
          id="getting-started-gateway-systemd"
          class="text-xs rounded"
        >{SiteComponents.gateway_systemd_command(@gateway_env) |> String.trim()}</Core.code_block>
      </div>
    </div>
    """
  end

  # ── Shared pieces ───────────────────────────────────────────────────────────

  attr :account, :any, required: true
  attr :first, :any, required: true
  attr :client_tab, :string, required: true
  attr :target, :any, required: true
  attr :lead, :string, default: "This computer becomes your first device."

  defp install_this_computer(assigns) do
    ~H"""
    <h4 class="text-base font-semibold text-heading">Install Firezone on this computer</h4>
    <p class="mt-1 mb-4 text-sm text-body">{@lead}</p>
    <.client_install account={@account} client_tab={@client_tab} target={@target} />
    <.live_status
      id="getting-started-status-0"
      done?={@first != nil}
      waiting="Waiting for this computer to sign in…"
      waiting_hint="This updates automatically."
      done={@first && "#{@first.name} is online"}
      done_hint={@first && "Reachable at #{@first.fqdn}"}
    />
    """
  end

  attr :account, :any, required: true
  attr :client_tab, :string, required: true
  attr :target, :any, required: true

  # Installing a Client is a download, an installer and a sign in, so the steps for
  # the chosen platform are shown right here rather than linked to.
  defp client_install(assigns) do
    assigns = assign(assigns, tabs: @client_tabs, client: client(assigns.client_tab))

    ~H"""
    <div class="mb-4">
      <.tabs id="getting-started-client-tabs" tabs={@tabs} selected={@client_tab} event="client_tab" target={@target} />
      <ol id={"getting-started-client-#{@client_tab}"} class="space-y-2 text-sm text-body list-decimal list-inside">
        <li>
          <a
            href={@client.download}
            class="inline-flex items-center gap-1.5 font-medium text-link hover:underline"
          >
            <Core.icon name="ri-download-2-line" class="w-4 h-4" />Download Firezone for {@client.label}
          </a>
          <span :if={@client[:download_arm]} class="text-subtle">
            (or for <a href={@client.download_arm} class="text-link hover:underline">ARM64</a>)
          </span>
        </li>
        <li>{@client.install}</li>
        <li>
          {@client.open} and sign in to <span class="font-medium text-heading">{@account.slug}</span>.
        </li>
      </ol>
      <p class="mt-2 text-xs text-subtle">
        <Navigation.website_link path={@client.docs}>Other ways to install</Navigation.website_link>
      </p>
    </div>
    """
  end

  defp client("windows") do
    %{
      label: "Windows",
      download: "https://www.firezone.dev/dl/firezone-client-gui-windows/latest/x86_64",
      install: "Run the installer.",
      open: "Open Firezone from the system tray",
      docs: "/kb/client-apps/windows-gui-client"
    }
  end

  defp client("linux") do
    %{
      label: "Linux",
      download: "https://www.firezone.dev/dl/firezone-client-gui-linux/latest/x86_64.deb",
      download_arm: "https://www.firezone.dev/dl/firezone-client-gui-linux/latest/aarch64.deb",
      install: "Install the downloaded package, for example with: sudo apt install ./<file>.deb",
      open: "Open Firezone",
      docs: "/kb/client-apps/linux-gui-client"
    }
  end

  defp client(_macos) do
    %{
      label: "macOS",
      download: "https://www.firezone.dev/dl/firezone-client-macos/latest",
      install: "Open the download and install Firezone.",
      open: "Open Firezone from the menu bar",
      docs: "/kb/client-apps/macos-client"
    }
  end

  attr :id, :string, required: true
  attr :tabs, :list, required: true
  attr :selected, :string, required: true
  attr :event, :string, required: true
  attr :target, :any, required: true

  defp tabs(assigns) do
    ~H"""
    <div id={@id} class="flex gap-1.5 mb-3" role="tablist">
      <button
        :for={{tab, label, icon} <- @tabs}
        id={"#{@id}-#{tab}"}
        type="button"
        role="tab"
        aria-selected={to_string(@selected == tab)}
        phx-click={@event}
        phx-value-tab={tab}
        phx-target={@target}
        class={[
          "inline-flex items-center gap-1.5 px-3 py-1.5 rounded text-xs font-medium border transition-colors",
          if(@selected == tab,
            do: "border-brand bg-brand-muted text-heading",
            else: "border-border text-body hover:text-heading hover:bg-raised"
          )
        ]}
      >
        <Core.icon name={icon} class="w-3.5 h-3.5 shrink-0" />
        {label}
      </button>
    </div>
    """
  end

  attr :title, :string, required: true
  slot :lead

  slot :link do
    attr :icon, :string, required: true
    attr :website, :string
    attr :navigate, :string
  end

  defp finished(assigns) do
    ~H"""
    <div class="text-center">
      <div class="mx-auto mb-3 w-12 h-12 rounded-full flex items-center justify-center bg-success text-white">
        <Core.icon name="ri-check-line" class="w-6 h-6" />
      </div>
      <h4 class="text-base font-semibold text-heading">{@title}</h4>
      <p :for={lead <- @lead} class="mt-1 mb-5 text-sm text-body">{render_slot(lead)}</p>
    </div>
    <ul class="border-t border-border pt-3 space-y-1">
      <li :for={link <- @link}>
        <Navigation.website_link
          :if={link[:website]}
          path={link[:website]}
          class="flex items-center gap-3 p-2 rounded text-sm text-body hover:bg-raised hover:text-heading"
        >
          <Core.icon name={link.icon} class="w-4 h-4 text-subtle" />
          {render_slot(link)}
          <Core.icon name="ri-external-link-line" class="w-4 h-4 ml-auto text-subtle" />
        </Navigation.website_link>
        <.link
          :if={link[:navigate]}
          navigate={link[:navigate]}
          class="flex items-center gap-3 p-2 rounded text-sm text-body hover:bg-raised hover:text-heading"
        >
          <Core.icon name={link.icon} class="w-4 h-4 text-subtle" />
          {render_slot(link)}
          <Core.icon name="ri-arrow-right-line" class="w-4 h-4 ml-auto text-subtle" />
        </.link>
      </li>
    </ul>
    """
  end

  attr :step, :integer, required: true
  attr :total, :integer, required: true
  attr :done, :integer, required: true

  defp stepper(assigns) do
    ~H"""
    <div class="mb-4">
      <div class="flex gap-1.5">
        <div
          :for={i <- 0..(@total - 1)}
          class={[
            "flex-1 h-1 rounded-full transition-colors",
            cond do
              i < @done -> "bg-success"
              i == @step -> "bg-brand"
              true -> "bg-border-strong"
            end
          ]}
        >
        </div>
      </div>
      <p class="mt-2 text-xs font-semibold tracking-wider uppercase text-subtle">
        Step {@step + 1} of {@total}
      </p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :done?, :boolean, required: true
  attr :waiting, :string, required: true
  attr :waiting_hint, :string, required: true
  attr :done, :string, default: nil
  attr :done_hint, :string, default: nil

  defp live_status(assigns) do
    ~H"""
    <div
      id={@id}
      role="status"
      aria-live="polite"
      data-done={to_string(@done?)}
      class={[
        "flex items-center gap-3 px-4 py-3 rounded-lg border text-sm transition-colors",
        if(@done?,
          do: "border-success bg-success-light",
          else: "border-dashed border-border-emphasis bg-raised"
        )
      ]}
    >
      <span :if={not @done?} class="relative flex shrink-0 w-2.5 h-2.5">
        <span class="absolute inline-flex w-full h-full rounded-full bg-brand opacity-60 animate-ping">
        </span>
        <span class="relative inline-flex w-2.5 h-2.5 rounded-full bg-brand"></span>
      </span>
      <span
        :if={@done?}
        class="shrink-0 w-6 h-6 rounded-full flex items-center justify-center bg-success text-white"
      >
        <Core.icon name="ri-check-line" class="w-4 h-4" />
      </span>
      <div>
        <p class={["font-medium", if(@done?, do: "text-success", else: "text-heading")]}>
          {if @done?, do: @done, else: @waiting}
        </p>
        <p class="text-xs text-subtle">{if @done?, do: @done_hint, else: @waiting_hint}</p>
      </div>
    </div>
    """
  end

  attr :view, :atom, required: true
  attr :step, :integer, required: true
  attr :done?, :boolean, required: true
  attr :submit_address?, :boolean, required: true
  attr :target, :any, required: true

  # Going back sits on the left and going forward on the right, like the other
  # modals. The first step and the finish screen have nothing to go back to, so the
  # same button returns to the goal chooser there.
  defp footer(assigns) do
    {doc_path, doc_label} = footer_doc(assigns.view, assigns.step)

    assigns =
      assign(assigns,
        total: total_steps(assigns.view),
        doc_path: doc_path,
        doc_label: doc_label
      )

    ~H"""
    <Form.button
      id="getting-started-back"
      type="button"
      style="info"
      icon="ri-arrow-left-line"
      phx-click={if @step in [0, @total], do: "change_goal", else: "back"}
      phx-target={@target}
    >
      {if @step in [0, @total], do: "Change goal", else: "Back"}
    </Form.button>
    <div class="flex items-center gap-4">
      <Navigation.website_link
        path={@doc_path}
        class="inline-flex items-center gap-1 text-sm text-subtle hover:text-heading"
      >
        <Core.icon name="ri-book-open-line" class="w-4 h-4" />
        {@doc_label}
      </Navigation.website_link>
      <Form.button
        :if={@submit_address?}
        id="getting-started-continue"
        type="submit"
        form="getting-started-address-form"
        style="primary"
      >
        Save and continue
      </Form.button>
      <Form.button
        :if={not @submit_address?}
        id="getting-started-continue"
        type="button"
        style="primary"
        disabled={not @done?}
        phx-click={if @step == @total, do: "complete", else: "continue"}
        phx-target={@target}
      >
        {if @step == @total, do: "Done", else: "Continue"}
      </Form.button>
    </div>
    """
  end

  defp footer_doc(:device_mesh, 2), do: {"/kb/administer/troubleshooting", "Troubleshoot connectivity"}
  defp footer_doc(:device_mesh, _step), do: {"/kb/client-apps", "Install guide"}
  defp footer_doc(:remote_access, 0), do: {"/kb/client-apps", "Install guide"}
  defp footer_doc(:remote_access, 1), do: {"/kb/concepts/resources", "What is a Resource?"}
  defp footer_doc(:remote_access, 2), do: {"/kb/deploy/gateways", "Deploy a Gateway"}
  defp footer_doc(:remote_access, _step), do: {"/kb/administer/troubleshooting", "Troubleshoot access"}

  # ── Events ──────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("choose", %{"goal" => goal}, socket) when is_map_key(@goals, goal) do
    goal = Map.fetch!(@goals, goal)

    case save(socket, %{getting_started: goal}) do
      {:ok, socket} -> {:noreply, start(socket, goal)}
      {:error, socket} -> {:noreply, socket}
    end
  end

  def handle_event("open", _params, %{assigns: %{goal: goal}} = socket) when goal in @flows do
    {:noreply, socket |> assign(open?: true) |> start(goal)}
  end

  def handle_event("open", _params, socket) do
    {:noreply, assign(socket, open?: true, view: :chooser)}
  end

  def handle_event("change_goal", _params, socket) do
    {:noreply, assign(socket, view: :chooser, poll_ref: nil)}
  end

  def handle_event("continue", _params, %{assigns: %{view: view, step: step}} = socket)
      when view in @flows do
    if step < total_steps(view) and step_done?(socket.assigns, step) do
      {:noreply, socket |> assign(step: step + 1) |> enter_step()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("back", _params, %{assigns: %{view: view, step: step}} = socket)
      when view in @flows and step > 0 do
    {:noreply, socket |> assign(step: step - 1) |> enter_step()}
  end

  def handle_event("validate_address", %{"resource" => %{"address" => address}}, socket) do
    form = address |> Database.address_changeset(socket.assigns.subject) |> validate_form()
    {:noreply, assign(socket, address_form: form)}
  end

  def handle_event("example_address", %{"address" => address}, socket) do
    form = address |> Database.address_changeset(socket.assigns.subject) |> to_form(as: :resource)
    {:noreply, assign(socket, address_form: form)}
  end

  def handle_event(
        "save_address",
        %{"resource" => %{"address" => address}},
        %{assigns: %{view: :remote_access, step: 1, resource: nil}} = socket
      ) do
    with {:ok, resource} <- Database.create_resource(address, socket.assigns.subject),
         {:ok, socket} <- save(socket, %{getting_started_resource_id: resource.id}) do
      {:noreply, socket |> assign(resource: resource, step: 2) |> enter_step()}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, address_form: validate_form(changeset))}

      {:error, socket} ->
        {:noreply, socket}
    end
  end

  def handle_event("deploy_tab", %{"tab" => tab}, socket) when tab in @deploy_tab_values do
    {:noreply, assign(socket, deploy_tab: tab)}
  end

  def handle_event("client_tab", %{"tab" => tab}, socket) when tab in @client_tab_values do
    {:noreply, assign(socket, client_tab: tab)}
  end

  # Finishing a goal, or choosing to explore alone, is the end of the guide: it
  # leaves the sidebar and the user menu.
  def handle_event("complete", _params, %{assigns: %{view: view, step: step}} = socket)
      when view in @flows do
    if step == total_steps(view), do: finish(socket, :completed), else: {:noreply, socket}
  end

  def handle_event("explore", _params, socket), do: finish(socket, :dismissed)

  # Closing the guide before picking a goal stops it opening by itself, but keeps it
  # in the sidebar. Closing it after picking one keeps the goal to come back to.
  def handle_event("dismiss", _params, %{assigns: %{pending?: true, open?: true}} = socket) do
    {_result, socket} = save(socket, %{getting_started: :closed})
    {:noreply, close(socket)}
  end

  def handle_event("dismiss", _params, socket) do
    {:noreply, close(socket)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp finish(socket, state) do
    {_result, socket} = save(socket, %{getting_started: state})
    {:noreply, close(socket)}
  end

  defp close(socket), do: assign(socket, open?: false, poll_ref: nil)

  defp save(socket, attrs) do
    case Database.update_preferences(socket.assigns.actor, attrs, socket.assigns.subject) do
      {:ok, actor} ->
        {:ok,
         assign(socket, actor: actor, pending?: false, goal: preference(actor, :getting_started))}

      {:error, _reason} ->
        {:error, put_flash(socket, :error, "Your progress couldn't be saved. Please try again.")}
    end
  end

  # ── Progress ────────────────────────────────────────────────────────────────

  # Opens on the first step that isn't done yet, so coming back to the guide later
  # picks up where things actually are rather than where the modal was left.
  defp start(socket, :device_mesh) do
    socket |> assign(view: :device_mesh, step: 0) |> refresh(check_reached?: true) |> resume()
  end

  defp start(socket, :remote_access) do
    resource =
      case preference(socket.assigns.actor, :getting_started_resource_id) do
        nil -> nil
        id -> Database.fetch_resource(id, socket.assigns.subject)
      end

    socket
    |> assign(view: :remote_access, step: 0, resource: resource, address_form: address_form())
    |> refresh(check_reached?: true)
    |> resume()
  end

  defp resume(socket) do
    total = total_steps(socket.assigns.view)
    step = Enum.find(0..(total - 1), total, &(not step_done?(socket.assigns, &1)))
    socket |> assign(step: step) |> enter_step()
  end

  # Looks at what's changed before showing a step, so a step that is already done
  # (say, a Gateway already online in the Site) shows as done straight away.
  defp enter_step(socket), do: socket |> refresh() |> prepare_step() |> ensure_polling()

  # The Gateway install command needs a token, and a token can only be shown when it
  # is created. It's only made when the step is actually on screen, and the Gateway
  # pre-created for it is remembered, so coming back to this step rotates that
  # Gateway's token instead of leaving another one behind.
  defp prepare_step(
         %{
           assigns: %{
             open?: true,
             view: :remote_access,
             step: 2,
             gateway_env: nil,
             gateway_online?: false
           }
         } = socket
       ) do
    %{resource: resource, actor: actor, subject: subject} = socket.assigns
    gateway_id = preference(actor, :getting_started_gateway_id)

    with {:ok, gateway_id, token} <- Database.gateway_token(gateway_id, resource.site_id, subject),
         {:ok, socket} <- save(socket, %{getting_started_gateway_id: gateway_id}) do
      assign(socket, gateway_env: SiteComponents.gateway_env(token))
    else
      {:error, %Phoenix.LiveView.Socket{} = socket} ->
        socket

      {:error, _reason} ->
        put_flash(socket, :error, "The Gateway install command couldn't be created. Please try again.")
    end
  end

  defp prepare_step(socket), do: socket

  defp total_steps(:device_mesh), do: 3
  defp total_steps(:remote_access), do: 4

  defp step_done?(%{view: view} = assigns, step), do: step_done?(view, step, assigns)

  defp step_done?(:device_mesh, 0, %{devices: devices}), do: devices != []
  defp step_done?(:device_mesh, 1, %{devices: devices}), do: match?([_, _ | _], devices)
  defp step_done?(:device_mesh, 2, %{connected?: connected?}), do: connected?
  defp step_done?(:remote_access, 0, %{devices: devices}), do: devices != []
  defp step_done?(:remote_access, 1, %{resource: resource}), do: resource != nil
  defp step_done?(:remote_access, 2, %{gateway_online?: online?}), do: online?
  defp step_done?(:remote_access, 3, %{reached?: reached?}), do: reached?
  defp step_done?(_view, _step, _assigns), do: true

  defp done_count(view, step, assigns) do
    Enum.count(0..step, &step_done?(view, &1, assigns))
  end

  # Looks again at what may have changed outside the portal. Presence is in memory;
  # the database is only asked about new devices and, on the last step, about the
  # connection, unless `check_reached?: true` asks for it right away.
  defp refresh(socket, opts \\ []) do
    %{view: view, step: step} = socket.assigns
    check_reached? = Keyword.get(opts, :check_reached?, step >= total_steps(view) - 1)

    socket
    |> refresh_devices()
    |> refresh_progress(view, check_reached?)
  end

  # The first two of the actor's clients to come online are "this computer" and the
  # second one. They're remembered once seen, so a device dropping offline later
  # doesn't undo a step that was already done.
  defp refresh_devices(socket) do
    %{subject: subject, devices: known} = socket.assigns
    known_ids = MapSet.new(known, & &1.id)

    new_ids =
      subject
      |> online_client_ids()
      |> Enum.reject(&MapSet.member?(known_ids, &1))
      |> Enum.take(2 - length(known))

    case new_ids do
      [] -> socket
      ids -> assign(socket, devices: known ++ Database.list_devices(ids, subject))
    end
  end

  defp refresh_progress(socket, :device_mesh, check_reached?) do
    %{devices: devices, connected?: connected?, subject: subject} = socket.assigns

    connected? =
      connected? or
        (check_reached? and match?([_, _ | _], devices) and
           Database.connected?(Enum.map(devices, & &1.id), subject))

    assign(socket, connected?: connected?)
  end

  defp refresh_progress(%{assigns: %{resource: nil}} = socket, :remote_access, _check?) do
    socket
  end

  defp refresh_progress(socket, :remote_access, check_reached?) do
    %{resource: resource, subject: subject, reached?: reached?} = socket.assigns
    online_sites = Presence.Devices.online_site_ids(subject.account.id)

    assign(socket,
      gateway_online?: MapSet.member?(online_sites, resource.site_id),
      reached?: reached? or (check_reached? and Database.reached?(resource.id, subject))
    )
  end

  defp online_client_ids(subject) do
    actor_id = subject.actor.id

    subject.account.id
    |> Presence.Devices.Account.list()
    |> Enum.flat_map(fn
      {id, %{metas: [%{type: :client, actor_id: ^actor_id} = meta | _]}} ->
        [{Map.get(meta, :online_at, 0), id}]

      _other ->
        []
    end)
    |> Enum.sort()
    |> Enum.map(&elem(&1, 1))
  end

  # Entering an address waits on the admin, not on something outside the portal.
  defp polling?(%{assigns: %{open?: true, view: view, step: step}}) when view in @flows do
    step < total_steps(view) and {view, step} != {:remote_access, 1}
  end

  defp polling?(_socket), do: false

  # A fresh ref retires whatever loop was running, so only one ever is.
  defp ensure_polling(socket) do
    if polling?(socket), do: socket |> assign(poll_ref: make_ref()) |> schedule_poll(), else: socket
  end

  defp schedule_poll(socket) do
    if polling?(socket) do
      send_update_after(socket.assigns.myself, %{poll: socket.assigns.poll_ref}, poll_interval_ms())
    end

    socket
  end

  defp poll_interval_ms do
    Portal.Config.get_env(:portal, __MODULE__, [])
    |> Keyword.get(:poll_interval_ms, 2_000)
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp address_form, do: "" |> Database.address_changeset(nil) |> to_form(as: :resource)

  # The Resource is named after its address, so a problem with the name (such as
  # being too long) is shown on the address the admin typed.
  defp validate_form(changeset) do
    name_errors = for {:name, error} <- changeset.errors, do: {:address, error}

    %{changeset | errors: changeset.errors ++ name_errors, action: :validate}
    |> to_form(as: :resource)
  end

  # The platform the admin is browsing from, to show its install steps first.
  defp client_tab(user_agent) when is_binary(user_agent) do
    cond do
      user_agent =~ "Windows" -> "windows"
      user_agent =~ ~r/Linux|X11/ and not (user_agent =~ "Android") -> "linux"
      true -> "macos"
    end
  end

  defp client_tab(_user_agent), do: "macos"

  @doc false
  # What kind of Resource an address makes, the way the address field labels it.
  @spec address_type(String.t() | nil) :: :dns | :ip | :cidr | nil
  def address_type(address) when is_binary(address) do
    address = String.trim(address)

    cond do
      address == "" -> nil
      String.contains?(address, "/") -> :cidr
      match?({:ok, _}, address |> String.to_charlist() |> :inet.parse_strict_address()) -> :ip
      true -> :dns
    end
  end

  def address_type(_address), do: nil

  # A heading and an example command for reaching the Resource. Wildcard names have
  # no single host to show, so they only get the heading.
  defp try_it(%{type: :cidr, address: address}) do
    {"Reach something in #{address}", "ping #{first_host(address)}"}
  end

  defp try_it(%{type: :ip, address: address}), do: {"Reach #{address}", "ping #{address}"}
  defp try_it(%{address: "*" <> _ = address}), do: {"Reach a host in #{address}", nil}
  defp try_it(%{address: "?" <> _ = address}), do: {"Reach a host in #{address}", nil}
  defp try_it(%{address: address}), do: {"Open #{address}", "ping #{address}"}

  defp first_host(cidr) do
    [network | _] = String.split(cidr, "/")

    cond do
      String.ends_with?(network, "::") -> network <> "1"
      String.ends_with?(network, ".0") -> String.replace_suffix(network, ".0", ".1")
      true -> network
    end
  end

  defp pending?(actor), do: preference(actor, :getting_started) == :pending

  defp preference(%Portal.Actor{preferences: %Portal.Actor.Preferences{} = preferences}, key) do
    Map.fetch!(preferences, key)
  end

  defp preference(_actor, _key), do: nil

  defp title(:device_mesh, _actor), do: "Connect your devices"
  defp title(:remote_access, _actor), do: "Reach a remote network or service"

  defp title(:chooser, %Portal.Actor{name: name}) do
    case String.split(name || "") do
      [first_name | _] -> "Welcome to Firezone, #{first_name} 👋"
      [] -> "Welcome to Firezone 👋"
    end
  end

  defmodule Database do
    import Ecto.Changeset
    import Ecto.Query
    alias Portal.Actor.Preferences
    alias Portal.Device
    alias Portal.Group
    alias Portal.Policy
    alias Portal.PolicyAuthorization
    alias Portal.Resource
    alias Portal.Safe
    alias Portal.Site

    @default_site_name "Default Site"

    @spec update_preferences(Portal.Actor.t(), map(), Portal.Authentication.Subject.t()) ::
            {:ok, Portal.Actor.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
    def update_preferences(actor, attrs, subject) do
      actor
      |> cast(%{preferences: attrs}, [])
      |> cast_embed(:preferences, with: &Preferences.getting_started_changeset/2)
      |> Safe.scoped(subject)
      |> Safe.update()
    end

    @doc "The subject's own clients among `ids`, as name and DNS name, in the order of `ids`."
    @spec list_devices([Ecto.UUID.t()], Portal.Authentication.Subject.t()) :: [map()]
    def list_devices(ids, subject) do
      devices =
        from(d in Device, as: :devices)
        |> where([devices: d], d.type == :client)
        |> where([devices: d], d.actor_id == ^subject.actor.id)
        |> where([devices: d], d.id in ^ids)
        |> Safe.scoped(subject)
        |> Safe.all()
        |> Map.new(&{&1.id, %{id: &1.id, name: &1.name, fqdn: Device.fqdn(&1)}})

      ids |> Enum.map(&Map.get(devices, &1)) |> Enum.reject(&is_nil/1)
    end

    @doc "Whether any of the devices has been authorized to reach another of them."
    @spec connected?([Ecto.UUID.t()], Portal.Authentication.Subject.t()) :: boolean()
    def connected?(device_ids, subject) do
      from(pa in PolicyAuthorization, as: :policy_authorizations)
      |> where([policy_authorizations: pa], pa.initiating_device_id in ^device_ids)
      |> where([policy_authorizations: pa], pa.receiving_device_id in ^device_ids)
      |> exists?(subject)
    end

    @doc "Whether anyone has been authorized to reach the Resource."
    @spec reached?(Ecto.UUID.t(), Portal.Authentication.Subject.t()) :: boolean()
    def reached?(resource_id, subject) do
      from(pa in PolicyAuthorization, as: :policy_authorizations)
      |> where([policy_authorizations: pa], pa.resource_id == ^resource_id)
      |> exists?(subject)
    end

    defp exists?(query, subject) do
      query
      |> limit(1)
      |> Safe.scoped(subject)
      |> Safe.one()
      |> case do
        %PolicyAuthorization{} -> true
        _none_or_error -> false
      end
    end

    @spec fetch_resource(Ecto.UUID.t(), Portal.Authentication.Subject.t()) :: Resource.t() | nil
    def fetch_resource(id, subject) do
      from(r in Resource, as: :resources)
      |> where([resources: r], r.id == ^id and r.type in [:dns, :ip, :cidr])
      |> Safe.scoped(subject)
      |> Safe.one()
      |> case do
        %Resource{} = resource -> resource
        _none_or_error -> nil
      end
    end

    @doc """
    Validates an address the way the Resource it becomes will be, short of its Site.
    The Resource is named after its address.
    """
    @spec address_changeset(String.t(), Portal.Authentication.Subject.t() | nil) ::
            Ecto.Changeset.t()
    def address_changeset(address, subject) do
      type = PortalWeb.GettingStarted.address_type(address) || :dns

      %Resource{account_id: subject && subject.account.id}
      |> cast(%{address: address, name: address, type: type}, [:address, :name, :type])
      |> Resource.changeset()
      |> validate_required([:address])
    end

    @doc """
    Creates a Resource for `address` in the Default Site, and a Policy that lets
    Everyone reach it.
    """
    @spec create_resource(String.t(), Portal.Authentication.Subject.t()) ::
            {:ok, Resource.t()} | {:error, Ecto.Changeset.t()}
    def create_resource(address, subject) do
      Safe.transact(fn ->
        with {:ok, site} <- default_site(subject),
             {:ok, group} <- everyone_group(subject),
             {:ok, resource} <- insert_resource(address, site, subject),
             {:ok, _policy} <- insert_policy(group, resource, subject) do
          {:ok, resource}
        else
          {:error, %Ecto.Changeset{data: %Resource{}} = changeset} ->
            {:error, changeset}

          {:error, _reason} ->
            {:error,
             address
             |> address_changeset(subject)
             |> add_error(:address, "couldn't be added. Please try again.")}
        end
      end)
    end

    defp insert_resource(address, site, subject) do
      address
      |> address_changeset(subject)
      |> put_change(:site_id, site.id)
      |> Resource.validate_site_matches_type(subject)
      |> Safe.scoped(subject)
      |> Safe.insert()
    end

    # Sign up names it "Default Site"; if it was renamed or removed, the oldest Site
    # the account manages stands in, and one is made when there is none.
    defp default_site(subject) do
      sites =
        from(s in Site, as: :sites)
        |> where([sites: s], s.managed_by == :account)
        |> order_by([sites: s], desc: s.name == ^@default_site_name, asc: s.inserted_at)
        |> limit(1)
        |> Safe.scoped(subject)
        |> Safe.all()

      case sites do
        [site | _] ->
          {:ok, site}

        [] ->
          %Site{account_id: subject.account.id, managed_by: :account}
          |> cast(%{name: @default_site_name}, [:name])
          |> Site.changeset()
          |> Safe.scoped(subject)
          |> Safe.insert()

        {:error, _reason} = error ->
          error
      end
    end

    defp everyone_group(subject) do
      from(g in Group, as: :groups)
      |> where([groups: g], g.type == :managed and g.name == "Everyone")
      |> Safe.scoped(subject)
      |> Safe.one()
      |> case do
        %Group{} = group -> {:ok, group}
        _none_or_error -> {:error, :no_everyone_group}
      end
    end

    defp insert_policy(group, resource, subject) do
      %Policy{account_id: subject.account.id}
      |> cast(
        %{
          group_id: group.id,
          resource_id: resource.id,
          description: "Created by the getting started guide."
        },
        [:group_id, :resource_id, :description]
      )
      |> Policy.changeset()
      |> Safe.scoped(subject)
      |> Safe.insert()
    end

    @doc """
    A token for a Gateway in `site_id`: the remembered Gateway's, rotated, when it
    is still in that Site and has never connected; otherwise a newly provisioned one.
    """
    @spec gateway_token(Ecto.UUID.t() | nil, Ecto.UUID.t(), Portal.Authentication.Subject.t()) ::
            {:ok, Ecto.UUID.t(), String.t()} | {:error, term()}
    def gateway_token(gateway_id, site_id, subject) do
      case pending_gateway(gateway_id, site_id, subject) do
        %Device{} = gateway ->
          with {:ok, token} <- Portal.Authentication.rotate_gateway_token(gateway, subject) do
            {:ok, gateway.id, Portal.Authentication.encode_fragment!(token)}
          end

        nil ->
          with {:ok, site} <- fetch_site(site_id, subject),
               {:ok, gateway, _token, encoded} <-
                 Portal.Devices.provision_gateway(site, nil, subject) do
            {:ok, gateway.id, encoded}
          end
      end
    end

    defp pending_gateway(nil, _site_id, _subject), do: nil

    defp pending_gateway(gateway_id, site_id, subject) do
      from(d in Device, as: :devices)
      |> where([devices: d], d.id == ^gateway_id and d.type == :gateway)
      |> where([devices: d], d.site_id == ^site_id and is_nil(d.firezone_id))
      |> Safe.scoped(subject)
      |> Safe.one()
      |> case do
        %Device{} = gateway -> gateway
        _none_or_error -> nil
      end
    end

    defp fetch_site(site_id, subject) do
      from(s in Site, as: :sites)
      |> where([sites: s], s.id == ^site_id)
      |> Safe.scoped(subject)
      |> Safe.one()
      |> case do
        %Site{} = site -> {:ok, site}
        nil -> {:error, :not_found}
        {:error, _reason} = error -> error
      end
    end
  end
end
