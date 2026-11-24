defmodule PortalWeb.Access.Simulator do
  use PortalWeb, :live_view

  alias PortalWeb.Access.Components
  alias PortalWeb.Access.Simulator.Routing
  alias PortalWeb.Policies
  alias __MODULE__.Database

  @defaults %{"address" => "", "protocol" => "tcp", "port" => "443"}

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Simulator", query: nil, errors: %{})
      |> assign(form: to_form(@defaults, as: :simulation))
      |> assign(result: nil)

    {:ok, socket}
  end

  def handle_params(params, _uri, socket) do
    params = Map.merge(@defaults, Map.take(params, Map.keys(@defaults)))
    socket = assign(socket, form: to_form(params, as: :simulation))

    case Routing.parse(params) do
      {:ok, query} ->
        subject = socket.assigns.subject

        socket =
          socket
          |> assign(query: query, errors: %{})
          |> assign_async(:result, fn -> {:ok, %{result: simulate(query, subject)}} end, reset: true)

        {:noreply, socket}

      {:error, errors} ->
        {:noreply, assign(socket, query: nil, errors: errors, result: nil)}

      :empty ->
        {:noreply, assign(socket, query: nil, errors: %{}, result: nil)}
    end
  end

  def handle_event("change", %{"simulation" => params}, socket) do
    {:noreply, assign(socket, form: to_form(Map.merge(@defaults, params), as: :simulation))}
  end

  def handle_event("simulate", %{"simulation" => params}, socket) do
    params = Map.take(Map.merge(@defaults, params), Map.keys(@defaults))

    params =
      if params["protocol"] == "icmp" do
        Map.delete(params, "port")
      else
        params
      end

    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/access/simulator?#{params}")}
  end

  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full overflow-hidden">
      <Page.page_header>
        <:title>Simulator</:title>
        <:description>
          Enter an address, a protocol and a port to see which resource a device uses for it, who can reach it, and what each of them needs.
        </:description>
      </Page.page_header>

      <div class="flex-1 min-h-0 overflow-y-auto px-6 pb-10">
        <.simulation_form form={@form} errors={@errors} />

        <div :if={is_nil(@result)} id="simulator-intro" class="flex flex-col items-center gap-3 py-16 text-center">
          <Core.icon name="ri-flask-line" class="w-6 h-6 text-faint" />
          <p class="max-w-md text-sm text-muted">
            The simulator uses the rules the Firezone Client uses. It checks device pools first, then DNS resources, then CIDR and IP resources, then the Internet Resource, and picks the most specific match.
          </p>
        </div>

        <.async_result :let={result} :if={@result} assign={@result}>
          <:loading>
            <div id="simulator-loading" class="py-16 text-center text-sm text-muted">
              <Core.icon name="ri-loader-4-line" class="w-4 h-4 animate-spin align-text-bottom" /> Simulating
            </div>
          </:loading>
          <:failed>
            <p id="simulator-failed" class="py-16 text-center text-sm text-attn">
              Could not run the simulation. Try again.
            </p>
          </:failed>
          <.simulation_result account={@account} result={result} />
        </.async_result>
      </div>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :errors, :map, required: true

  defp simulation_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id="simulator-form"
      phx-change="change"
      phx-submit="simulate"
      class="flex flex-wrap items-start gap-3 py-2 mb-6 border-b border-hair pb-6"
    >
      <label class="flex flex-col gap-1">
        <span class="text-[11px] font-semibold tracking-[.12em] uppercase text-muted">Address</span>
        <input
          type="text"
          name={@form[:address].name}
          id={@form[:address].id}
          value={@form[:address].value}
          placeholder="10.0.0.5 or gitlab.example.com"
          autocomplete="off"
          spellcheck="false"
          class={[
            "w-72 px-3 py-1.5 text-sm font-mono bg-bg text-fg border placeholder:text-faint focus:border-fg focus:ring-0",
            if(@errors[:address], do: "border-attn", else: "border-rule")
          ]}
        />
        <span :if={@errors[:address]} id="simulator-address-error" class="text-xs text-attn">
          {@errors[:address]}
        </span>
      </label>
      <label class="flex flex-col gap-1">
        <span class="text-[11px] font-semibold tracking-[.12em] uppercase text-muted">Protocol</span>
        <select
          name={@form[:protocol].name}
          id={@form[:protocol].id}
          class="w-28 px-3 py-1.5 text-sm bg-bg text-fg border border-rule focus:border-fg focus:ring-0"
        >
          <option :for={{label, value} <- [{"TCP", "tcp"}, {"UDP", "udp"}, {"ICMP", "icmp"}]} value={value} selected={@form[:protocol].value == value}>
            {label}
          </option>
        </select>
      </label>
      <label :if={@form[:protocol].value != "icmp"} class="flex flex-col gap-1">
        <span class="text-[11px] font-semibold tracking-[.12em] uppercase text-muted">Port</span>
        <input
          type="text"
          inputmode="numeric"
          name={@form[:port].name}
          id={@form[:port].id}
          value={@form[:port].value}
          autocomplete="off"
          class={[
            "w-24 px-3 py-1.5 text-sm font-mono bg-bg text-fg border focus:border-fg focus:ring-0",
            if(@errors[:port], do: "border-attn", else: "border-rule")
          ]}
        />
        <span :if={@errors[:port]} id="simulator-port-error" class="text-xs text-attn">{@errors[:port]}</span>
      </label>
      <div class="flex flex-col gap-1">
        <span class="text-[11px] invisible">Run</span>
        <Form.button type="submit" style="primary" icon="ri-play-line">Simulate</Form.button>
      </div>
    </.form>
    """
  end

  attr :account, :any, required: true
  attr :result, :map, required: true

  defp simulation_result(assigns) do
    ~H"""
    <div id="simulator-result" class="space-y-10">
      <p id="simulator-summary" class="text-sm text-fg">
        <span class="font-mono font-medium">{Routing.destination_label(@result.query)}</span>
        over <span class="font-mono">{Routing.describe(@result.query)}</span>:
        {summary(@result)}
      </p>

      <ul :if={@result.notes != []} id="simulator-notes" class="space-y-1">
        <li :for={note <- @result.notes} class="flex items-start gap-1.5 text-xs text-muted">
          <Core.icon name="ri-information-line" class="w-3.5 h-3.5 shrink-0 mt-px" />
          <span>{note}</span>
        </li>
      </ul>

      <section id="simulator-matches">
        <Core.header>
          <:title>Matching resources, most specific first</:title>
        </Core.header>
        <p :if={@result.entries == []} class="py-4 text-sm text-muted">
          No resource covers this address. Devices send this traffic outside the tunnel.
        </p>
        <ol :if={@result.entries != []} class="border-t border-hair">
          <li
            :for={{entry, index} <- Enum.with_index(@result.entries, 1)}
            id={"simulator-match-#{entry.resource.id}"}
            data-tier={entry.tier}
            data-allowed={to_string(entry.allowed?)}
            class="flex flex-wrap items-start gap-x-4 gap-y-2 px-1 py-3 border-b border-hair"
          >
            <span class="w-6 pt-0.5 text-xs tabular-nums text-muted">{index}</span>
            <div class="min-w-0 flex-1 basis-64">
              <.link
                navigate={~p"/#{@account}/resources/#{entry.resource.id}"}
                class="flex items-center gap-2 text-sm font-medium text-fg hover:underline"
              >
                <Core.icon name={resource_icon(entry.resource)} class="w-4 h-4 text-muted shrink-0" />
                <span class="truncate">{entry.resource.name}</span>
              </.link>
              <p class="pl-6 text-xs text-muted">
                <span class="uppercase tracking-wide">{Routing.tier_label(entry.tier)}</span>
                · <span class="font-mono">{entry.reason}</span>
                <span :if={entry.resource.site}>· {entry.resource.site.name}</span>
              </p>
            </div>
            <div class="w-56 text-xs">
              <span :if={entry.allowed?} class="inline-flex items-center gap-1 text-fg">
                <Core.icon name="ri-check-line" class="w-3.5 h-3.5" /> {filter_label(entry.resource.filters)}
              </span>
              <span :if={not entry.allowed?} class="inline-flex items-center gap-1 text-attn">
                <Core.icon name="ri-forbid-line" class="w-3.5 h-3.5" />
                Filters refuse {Routing.describe(@result.query)}
              </span>
            </div>
            <div class="flex flex-wrap gap-1.5 basis-full pl-10 lg:basis-auto lg:pl-0 lg:w-1/3">
              <Components.chip
                :for={policy <- Map.get(@result.policies_by_resource, entry.resource.id, [])}
                navigate={~p"/#{@account}/policies/#{policy.id}"}
                icon={if policy.group.resource_id, do: "ri-user-line", else: "ri-group-line"}
                title="Open the policy"
              >
                {group_label(policy.group, @result.direct_people)}
              </Components.chip>
              <span
                :if={Map.get(@result.policies_by_resource, entry.resource.id, []) == []}
                class="text-xs text-muted"
              >
                No policy
              </span>
            </div>
          </li>
        </ol>
      </section>

      <section id="simulator-paths">
        <Core.header>
          <:title>Who can reach it</:title>
        </Core.header>
        <p class="mb-4 text-xs text-muted">
          A device takes only the first resource in the list that it has. It has a resource when one of its policies' conditions and posture checks hold, so a device that fails them on one step moves on to the next.
        </p>
        <p :if={@result.paths == []} id="simulator-nobody" class="py-4 text-sm text-muted">
          Nobody has a policy for these resources.
        </p>
        <div class="space-y-4">
          <.path_card
            :for={{path, index} <- Enum.with_index(@result.paths)}
            id={"simulator-path-#{index}"}
            account={@account}
            path={path}
            result={@result}
          />
        </div>
      </section>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :account, :any, required: true
  attr :path, :map, required: true
  attr :result, :map, required: true

  defp path_card(assigns) do
    ~H"""
    <article id={@id} data-reaches={to_string(@path.reaches?)} class="border border-hair">
      <header class="flex flex-wrap items-center gap-x-3 gap-y-1 px-4 py-3 border-b border-hair">
        <Core.icon
          name={if @path.reaches?, do: "ri-checkbox-circle-line", else: "ri-forbid-line"}
          class={["w-4 h-4", if(@path.reaches?, do: "text-fg", else: "text-attn")]}
        />
        <span class={["text-sm font-medium", if(@path.reaches?, do: "text-fg", else: "text-attn")]}>
          {path_title(@path)}
        </span>
        <span class="text-xs text-muted">{actor_count(@path.actors)}</span>
      </header>

      <details class="group/people px-4 py-2 border-b border-hair">
        <summary class="cursor-pointer list-none text-xs text-muted hover:text-fg">
          <Core.icon name="ri-arrow-right-s-line" class="w-3.5 h-3.5 align-text-bottom group-open/people:rotate-90" />
          {people_preview(@path.actors)}
        </summary>
        <ul class="flex flex-wrap gap-1.5 pt-2 pb-1">
          <li :for={actor <- Enum.take(@path.actors, 200)}>
            <Components.chip
              navigate={actor_path(@account, actor)}
              icon={if actor.type == :service_account, do: "ri-robot-2-line", else: "ri-user-line"}
            >
              {actor.name}
            </Components.chip>
          </li>
          <li :if={length(@path.actors) > 200} class="text-xs text-muted self-center">
            and {length(@path.actors) - 200} more
          </li>
        </ul>
      </details>

      <ol class="divide-y divide-hair">
        <li :for={{step, index} <- Enum.with_index(@path.steps)} class="flex gap-3 px-4 py-3" data-outcome={step.outcome}>
          <span class="w-16 shrink-0 pt-px text-[11px] font-semibold tracking-[.12em] uppercase text-muted">
            {if index == 0, do: "First", else: "Else"}
          </span>
          <div class="min-w-0 flex-1 space-y-2">
            <p class="text-sm">
              <Core.icon
                name={step_icon(step.outcome)}
                class={["w-3.5 h-3.5 align-text-bottom", if(step.outcome == :reach, do: "text-fg", else: "text-attn")]}
              />
              <span class={if step.outcome == :reach, do: "text-fg", else: "text-attn"}>
                {step_verb(step)}
              </span>
              <.link navigate={~p"/#{@account}/resources/#{step.entry.resource.id}"} class="font-medium text-fg hover:underline">
                {step.entry.resource.name}
              </.link>
              <span :if={step.entry.tier == :internet} class="text-xs text-muted">
                when the device has the Internet Resource turned on
              </span>
            </p>
            <div :for={policy <- step.policies} class="flex flex-wrap items-start gap-3">
              <Components.chip
                navigate={~p"/#{@account}/policies/#{policy.id}"}
                icon={if policy.group.resource_id, do: "ri-user-line", else: "ri-group-line"}
                title="Open the policy"
              >
                {group_label(policy.group, @result.direct_people)}
              </Components.chip>
              <div class="min-w-0 flex-1 text-xs">
                <.policy_needs account={@account} policy={policy} result={@result} />
              </div>
            </div>
            <p :if={length(step.policies) > 1} class="text-xs text-muted">
              Each actor here has at least one of these policies, and one is enough.
            </p>
          </div>
        </li>
      </ol>
    </article>
    """
  end

  attr :account, :any, required: true
  attr :policy, :map, required: true
  attr :result, :map, required: true

  defp policy_needs(assigns) do
    ~H"""
    <p :if={Routing.unconditional?(@policy)} class="pt-0.5 text-muted">No conditions or posture checks</p>
    <div :if={not Routing.unconditional?(@policy)} class="space-y-2">
      <ul :if={@policy.conditions != []} class="space-y-2">
        <Policies.Components.policy_condition_row
          :for={condition <- @policy.conditions}
          account={@account}
          condition={condition}
          providers={@result.providers}
          disabled_providers={@result.disabled_providers}
        />
      </ul>
      <p :if={@policy.require_attestation} class="flex items-center gap-1.5 text-fg">
        <Core.icon name="ri-shield-check-line" class="w-3.5 h-3.5 text-muted" /> Device attestation required
      </p>
      <Policies.PostureComponents.postures_summary postures={@policy.postures} />
    </div>
    """
  end

  defp simulate(query, subject) do
    resources = Database.list_resources(Routing.resource_types(query), subject)
    entries = Routing.match(query, resources)
    policies = entries |> Enum.map(& &1.resource.id) |> Enum.uniq() |> Database.list_policies(subject)
    groups = policies |> Enum.map(& &1.group) |> Enum.uniq_by(& &1.id)
    everyone = Enum.find(groups, &everyone?/1)

    memberships = Database.memberships(Enum.map(groups, & &1.id), subject)
    actors = Database.list_actors(Enum.map(memberships, &elem(&1, 1)), not is_nil(everyone), subject)
    device = device_at(query, subject)
    holds = pool_holds(entries, device, subject)
    {disabled, active} = subject |> Database.list_providers() |> Enum.split_with(& &1.is_disabled)

    groups_by_actor = Enum.group_by(memberships, &elem(&1, 1), &elem(&1, 0))

    paths =
      actors
      |> Enum.map(fn actor ->
        group_ids = Map.get(groups_by_actor, actor.id, [])

        group_ids =
          if everyone && actor.type in [:account_user, :account_admin_user] do
            [everyone.id | group_ids]
          else
            group_ids
          end

        actor_policies =
          policies
          |> Enum.filter(&(&1.group_id in group_ids))
          |> Enum.group_by(& &1.resource_id)

        steps = Routing.paths(entries, actor_policies, &holds_device?(holds, &1, actor.id))
        {actor, steps}
      end)
      |> Enum.reject(fn {_actor, steps} -> steps == [] end)
      |> Enum.group_by(fn {_actor, steps} -> path_key(steps) end)
      |> Enum.map(fn {_key, [{_actor, steps} | _rest] = members} ->
        %{
          steps: merge_steps(steps, Enum.map(members, &elem(&1, 1))),
          actors: members |> Enum.map(&elem(&1, 0)) |> Enum.sort_by(&String.downcase(&1.name || "")),
          reaches?: Enum.any?(steps, &(&1.outcome == :reach))
        }
      end)
      |> Enum.sort_by(&{not &1.reaches?, -length(&1.actors), path_title(&1)})

    direct_group_ids = for group <- groups, group.resource_id, do: group.id

    %{
      query: query,
      entries: entries,
      paths: paths,
      policies_by_resource: Enum.group_by(policies, & &1.resource_id),
      direct_people: Components.direct_people(direct_group_ids, subject),
      providers: active,
      disabled_providers: disabled,
      notes: notes(query, entries, device)
    }
  end

  defp everyone?(group), do: group.type == :managed and group.name == "Everyone"

  defp device_at(%{destination: {:ip, ip}}, subject) do
    if Routing.tunnel?(ip) do
      Database.device_at(ip, subject)
    end
  end

  defp device_at(_query, _subject), do: nil

  # For each pool that covers a tunnel address: `:all` when it holds the device there for
  # everyone, or the actors for whom it holds it (`My devices` holds each actor's own).
  defp pool_holds(entries, device, subject) do
    for %{tier: :device_pool, resource: pool} <- entries, into: %{} do
      holds =
        cond do
          is_nil(device) -> MapSet.new()
          Portal.Resource.DeviceMembershipCriteria.kind(pool.device_membership_criteria) == :own_devices -> Database.device_actor_ids(device, subject)
          Database.pool_holds?(pool, device, subject) -> :all
          true -> MapSet.new()
        end

      {pool.id, holds}
    end
  end

  defp holds_device?(holds, entry, actor_id) do
    case Map.get(holds, entry.resource.id) do
      :all -> true
      %MapSet{} = actor_ids -> MapSet.member?(actor_ids, actor_id)
      nil -> false
    end
  end

  # Actors who take the same resources, each through some policy with nothing to check,
  # share a row whatever group gave them that policy.
  defp path_key(steps) do
    Enum.map(steps, fn step ->
      policies =
        if Routing.unconditional?(step.policies) do
          :unconditional
        else
          Enum.map(step.policies, & &1.id)
        end

      {step.outcome, step.entry.resource.id, policies}
    end)
  end

  defp merge_steps(steps, all_steps) do
    steps
    |> Enum.with_index()
    |> Enum.map(fn {step, index} ->
      if Routing.unconditional?(step.policies) do
        policies =
          all_steps
          |> Enum.flat_map(&Enum.at(&1, index).policies)
          |> Enum.filter(&Routing.unconditional?/1)
          |> Enum.uniq_by(& &1.id)

        %{step | policies: policies}
      else
        step
      end
    end)
  end

  defp notes(%{destination: {:domain, _domain}}, _entries, _device) do
    [
      "A name that no DNS resource the device has matches goes to the device's own DNS. CIDR and IP resources can still cover the address it gets back; enter that address to check them."
    ]
  end

  defp notes(%{destination: {:ip, ip}}, _entries, device) do
    cond do
      Routing.tunnel?(ip) and device ->
        ["#{device.name} uses this tunnel address. Device pools decide who reaches it."]

      Routing.tunnel?(ip) ->
        ["This is a tunnel address, but no device uses it."]

      true ->
        []
    end
  end

  defp summary(%{entries: []}), do: "no resource covers it."

  defp summary(%{entries: entries, paths: paths}) do
    reaching = paths |> Enum.filter(& &1.reaches?) |> Enum.flat_map(& &1.actors) |> length()

    resources =
      case Enum.count(entries) do
        1 -> "1 resource covers it"
        count -> "#{count} resources cover it"
      end

    "#{resources}, and #{actor_count_text(reaching)} can reach it."
  end

  defp path_title(%{steps: steps, reaches?: true}) do
    step = Enum.find(steps, &(&1.outcome == :reach))
    "Reaches it through #{step.entry.resource.name}"
  end

  defp path_title(%{steps: [step | _rest]}) do
    case step.outcome do
      :refused -> "Refused: #{step.entry.resource.name} does not hold this device"
      _blocked -> "Blocked by the filters on #{step.entry.resource.name}"
    end
  end

  defp step_verb(%{outcome: :reach}), do: "Uses"
  defp step_verb(%{outcome: :blocked}), do: "Dropped: the filters refuse it on"
  defp step_verb(%{outcome: :refused}), do: "Refused: the device is not in"

  defp step_icon(:reach), do: "ri-arrow-right-line"
  defp step_icon(:blocked), do: "ri-forbid-line"
  defp step_icon(:refused), do: "ri-close-circle-line"

  defp actor_count(actors), do: actor_count_text(length(actors))

  defp actor_count_text(1), do: "1 actor"
  defp actor_count_text(count), do: "#{count} actors"

  defp people_preview(actors) do
    names = actors |> Enum.take(4) |> Enum.map(& &1.name)

    case length(actors) - length(names) do
      0 -> Enum.join(names, ", ")
      more -> Enum.join(names, ", ") <> " and #{more} more"
    end
  end

  defp actor_path(account, %{type: :service_account} = actor), do: ~p"/#{account}/service_accounts/#{actor.id}"
  defp actor_path(account, actor), do: ~p"/#{account}/actors/#{actor.id}"

  defp group_label(%{resource_id: nil, name: name}, _direct_people), do: name

  defp group_label(group, direct_people) do
    direct_people |> Map.get(group.id, []) |> Components.people_label()
  end

  defp resource_icon(%{type: :dns}), do: "ri-global-line"
  defp resource_icon(%{type: :internet}), do: "ri-earth-line"
  defp resource_icon(%{type: :device_pool}), do: "ri-computer-line"
  defp resource_icon(_resource), do: "ri-server-line"

  defp filter_label([]), do: "All traffic"

  defp filter_label(filters) do
    Enum.map_join(filters, ", ", fn
      %{protocol: :icmp} -> "ICMP"
      %{protocol: protocol, ports: []} -> "#{String.upcase(to_string(protocol))} all ports"
      %{protocol: protocol, ports: ports} -> "#{String.upcase(to_string(protocol))} #{Enum.join(ports, ", ")}"
    end)
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{Safe, Actor, Device, DeviceActor, Group, Membership, Policy, Resource}
    alias Portal.Resource.DeviceMembershipCriteria

    def list_resources(types, subject) do
      from(r in Resource, where: r.type in ^types, preload: :site)
      |> Safe.scoped(subject)
      |> Safe.all()
      |> ok_list()
    end

    def list_policies([], _subject), do: []

    def list_policies(resource_ids, subject) do
      from(p in Policy,
        join: g in Group,
        on: g.id == p.group_id and g.account_id == p.account_id,
        where: p.resource_id in ^resource_ids and p.is_disabled == false,
        order_by: [asc: not is_nil(g.resource_id), asc: g.name],
        preload: [group: g]
      )
      |> Safe.scoped(subject)
      |> Safe.all()
      |> ok_list()
    end

    def memberships([], _subject), do: []

    def memberships(group_ids, subject) do
      from(m in Membership, where: m.group_id in ^group_ids, select: {m.group_id, m.actor_id})
      |> Safe.scoped(subject)
      |> Safe.all()
      |> ok_list()
    end

    # Actors that can sign in from a device. The `Everyone` group holds every user.
    def list_actors(actor_ids, everyone?, subject) do
      from(a in Actor,
        where: a.is_disabled == false,
        where: a.type in [:account_user, :account_admin_user, :service_account],
        select: %{id: a.id, name: a.name, type: a.type}
      )
      |> where([a], a.id in ^Enum.uniq(actor_ids) or (^everyone? and a.type in [:account_user, :account_admin_user]))
      |> Safe.scoped(subject)
      |> Safe.all()
      |> ok_list()
    end

    def device_at(ip, subject) do
      {:ok, inet} = Portal.Types.IP.cast(ip)

      from(d in Device,
        where: d.ipv4 == type(^inet, Portal.Types.IP) or d.ipv6 == type(^inet, Portal.Types.IP),
        limit: 1
      )
      |> Safe.scoped(subject)
      |> Safe.one()
      |> case do
        %Device{} = device -> device
        _other -> nil
      end
    end

    def device_actor_ids(%Device{} = device, subject) do
      from(da in DeviceActor, where: da.device_id == ^device.id, select: da.actor_id)
      |> Safe.scoped(subject)
      |> Safe.all()
      |> ok_list()
      |> MapSet.new()
    end

    def pool_holds?(%Resource{device_membership_criteria: criteria}, %Device{} = device, subject) do
      from(d in Device, as: :devices, where: d.id == ^device.id, select: true)
      |> where(^DeviceMembershipCriteria.targets())
      |> DeviceMembershipCriteria.where_members(criteria, :all)
      |> Safe.scoped(subject)
      |> Safe.one()
      |> Kernel.==(true)
    end

    def list_providers(subject) do
      schemas = [
        Portal.Userpass.AuthProvider,
        Portal.EmailOTP.AuthProvider,
        Portal.OIDC.AuthProvider,
        Portal.Google.AuthProvider,
        Portal.GitHub.AuthProvider,
        Portal.Entra.AuthProvider,
        Portal.Okta.AuthProvider,
        Portal.X509.AuthProvider
      ]

      Enum.flat_map(schemas, fn schema ->
        schema
        |> Safe.scoped(subject)
        |> Safe.all()
        |> ok_list()
      end)
    end

    defp ok_list({:error, _reason}), do: []
    defp ok_list(rows), do: rows
  end
end
