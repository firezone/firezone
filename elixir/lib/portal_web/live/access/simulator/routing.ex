defmodule PortalWeb.Access.Simulator.Routing do
  @moduledoc """
  How a Client picks the resource for one packet, ported from connlib
  (`client/routing.rs`, `routing_table.rs`, `dns/pattern.rs` and `filter_engine.rs`
  in `rust/libs/connlib/tunnel-proto`).

  The Client looks in four tables, in this order: device pools, DNS resources, CIDR and
  IP resources, then the Internet Resource. The first table that covers the destination
  decides. In that table, entries whose filters do not permit the packet drop out, and
  the rest are ordered most specific first:

    1. the DNS pattern (`example.com` before `?.example.com` before `*.example.com`),
    2. the longer network prefix,
    3. the narrower filter (fewer permitted ports),
    4. the greater resource id.

  Traffic only takes the first entry. If the table covers the destination but every
  entry's filters refuse the packet, the Client drops it and never looks further.

  A Client only has the resources for which one of its policies conforms (conditions,
  posture and attestation). So a device that fails the policy on the most specific
  resource uses the next one it has. `paths/3` follows that for one actor.
  """

  alias Portal.Types.CIDR

  @tiers [:device_pool, :dns, :cidr, :internet]
  @wildcards [?*, ??]
  @permit_all 4_294_967_295
  @ipv4_tunnel %Postgrex.INET{address: {100, 64, 0, 0}, netmask: 11}
  @ipv6_tunnel %Postgrex.INET{address: {0xFD00, 0x2021, 0x1111, 0, 0, 0, 0, 0}, netmask: 107}
  @domain ~r/\A[a-z0-9_-]+(\.[a-z0-9_-]+)*\z/

  @type destination :: {:ip, :inet.ip_address()} | {:domain, String.t()}
  @type query :: %{destination: destination(), protocol: :tcp | :udp | :icmp, port: 0..65_535 | nil}

  @type entry :: %{
          resource: Portal.Resource.t(),
          tier: :device_pool | :dns | :cidr | :internet,
          reason: String.t(),
          allowed?: boolean(),
          prefix: non_neg_integer(),
          breadth: non_neg_integer()
        }

  @type step :: %{outcome: :reach | :blocked | :refused, entry: entry(), policies: [map()]}

  @doc """
  Reads the form. Returns `:empty` until an address is given.
  """
  @spec parse(map()) :: {:ok, query()} | {:error, %{atom() => String.t()}} | :empty
  def parse(params) do
    address = params |> Map.get("address", "") |> to_string() |> String.trim()
    protocol = parse_protocol(Map.get(params, "protocol"))

    if address == "" do
      :empty
    else
      destination = parse_destination(address)
      port = parse_port(protocol, Map.get(params, "port"))

      errors =
        %{}
        |> put_error(:address, destination, "Enter an IP address or a domain name.")
        |> put_error(:port, port, "Enter a port from 0 to 65535.")

      if errors == %{} do
        {:ok, %{destination: elem(destination, 1), protocol: protocol, port: elem(port, 1)}}
      else
        {:error, errors}
      end
    end
  end

  @doc "The resource types that can cover the destination."
  @spec resource_types(query()) :: [atom()]
  def resource_types(%{destination: {:domain, _domain}}), do: [:dns, :internet]

  def resource_types(%{destination: {:ip, ip}}) do
    if tunnel?(ip) do
      [:device_pool, :cidr, :ip]
    else
      [:cidr, :ip, :internet]
    end
  end

  @doc "True for an address in the Client and device tunnel ranges."
  @spec tunnel?(:inet.ip_address()) :: boolean()
  def tunnel?(ip) do
    inet = %Postgrex.INET{address: ip}
    CIDR.contains?(@ipv4_tunnel, inet) or CIDR.contains?(@ipv6_tunnel, inet)
  end

  @doc "The resources that cover the destination, in the order the Client tries them."
  @spec match(query(), [Portal.Resource.t()]) :: [entry()]
  def match(query, resources) do
    resources
    |> Enum.flat_map(&covers(query.destination, &1))
    |> Enum.map(fn {resource, tier, reason, prefix} ->
      %{
        resource: resource,
        tier: tier,
        reason: reason,
        prefix: prefix,
        allowed?: allows?(resource.filters, query.protocol, query.port),
        breadth: breadth(resource.filters)
      }
    end)
    |> Enum.sort(&precedes?/2)
  end

  @doc """
  What happens to one actor's traffic, as a list of steps. Each step applies when one of
  its policies conforms on the device and no earlier step applied. The list stops at the
  first step that always applies.

  `policies` maps a resource id to the enabled policies through which the actor can reach
  it. `holds_device?` answers for a device pool entry whether it holds the target device
  for this actor.
  """
  @spec paths([entry()], %{Ecto.UUID.t() => [map()]}, (entry() -> boolean())) :: [step()]
  def paths(entries, policies, holds_device?) do
    entries
    |> Enum.chunk_by(& &1.tier)
    |> Enum.reduce_while([], fn tier_entries, steps ->
      tier_steps =
        for entry <- tier_entries,
            entry_policies = Map.get(policies, entry.resource.id, []),
            entry_policies != [] do
          %{outcome: outcome(entry, holds_device?), entry: entry, policies: entry_policies}
        end
        |> Enum.sort_by(&outcome_rank(&1.outcome))

      case Enum.split_while(tier_steps, &(not unconditional?(&1.policies))) do
        {kept, []} -> {:cont, steps ++ kept}
        {kept, [final | _rest]} -> {:halt, steps ++ kept ++ [final]}
      end
    end)
  end

  @doc "True when nothing on the device can make the policy fail."
  @spec unconditional?([map()] | map()) :: boolean()
  def unconditional?(policies) when is_list(policies), do: Enum.any?(policies, &unconditional?/1)

  def unconditional?(policy) do
    policy.conditions == [] and is_nil(policy.postures) and policy.require_attestation != true
  end

  @doc "A packet description such as `TCP 443` or `ICMP`."
  @spec describe(query()) :: String.t()
  def describe(%{protocol: :icmp}), do: "ICMP"
  def describe(%{protocol: protocol, port: port}), do: "#{String.upcase(to_string(protocol))} #{port}"

  @doc "The destination as typed back to the person."
  @spec destination_label(query()) :: String.t()
  def destination_label(%{destination: {:domain, domain}}), do: domain
  def destination_label(%{destination: {:ip, ip}}), do: ip |> :inet.ntoa() |> to_string()

  @doc "The table a tier stands for, for people."
  @spec tier_label(atom()) :: String.t()
  def tier_label(:device_pool), do: "Device pool"
  def tier_label(:dns), do: "DNS"
  def tier_label(:cidr), do: "CIDR or IP"
  def tier_label(:internet), do: "Internet"

  defp parse_protocol("udp"), do: :udp
  defp parse_protocol("icmp"), do: :icmp
  defp parse_protocol(_protocol), do: :tcp

  defp parse_destination(address) do
    case address |> String.to_charlist() |> :inet.parse_strict_address() do
      {:ok, ip} ->
        {:ok, {:ip, Portal.Types.IP.unmap(ip)}}

      {:error, _reason} ->
        domain = address |> String.downcase() |> String.trim_trailing(".")

        if byte_size(domain) <= 253 and Regex.match?(@domain, domain) do
          {:ok, {:domain, domain}}
        else
          :error
        end
    end
  end

  defp parse_port(:icmp, _port), do: {:ok, nil}

  defp parse_port(_protocol, port) do
    case Integer.parse(String.trim(to_string(port || ""))) do
      {port, ""} when port in 0..65_535 -> {:ok, port}
      _other -> :error
    end
  end

  defp put_error(errors, field, :error, message), do: Map.put(errors, field, message)
  defp put_error(errors, _field, {:ok, _value}, _message), do: errors

  defp covers({:ip, ip}, %{type: :device_pool} = resource) do
    if tunnel?(ip) do
      [{resource, :device_pool, "Holds devices at tunnel addresses", 0}]
    else
      []
    end
  end

  defp covers({:ip, ip}, %{type: :cidr, address: address} = resource) do
    with {:ok, cidr} <- CIDR.cast(address),
         true <- CIDR.contains?(cidr, %Postgrex.INET{address: ip}) do
      [{resource, :cidr, "In #{address}", cidr.netmask}]
    else
      _other -> []
    end
  end

  defp covers({:ip, ip}, %{type: :ip, address: address} = resource) do
    case Portal.Types.IP.cast(address) do
      {:ok, %Postgrex.INET{address: ^ip} = inet} ->
        [{resource, :cidr, "Exactly #{address}", CIDR.max_netmask(inet)}]

      _other ->
        []
    end
  end

  defp covers({:ip, ip}, %{type: :internet} = resource) do
    if tunnel?(ip) do
      []
    else
      [{resource, :internet, "Every address", 0}]
    end
  end

  defp covers({:domain, domain}, %{type: :dns, address: address} = resource) when is_binary(address) do
    if pattern_matches?(address, domain) do
      [{resource, :dns, "Matches #{address}", 0}]
    else
      []
    end
  end

  defp covers({:domain, _domain}, %{type: :internet} = resource) do
    [{resource, :internet, "Every name no DNS resource takes", 0}]
  end

  defp covers(_destination, _resource), do: []

  defp precedes?(left, right) do
    tier = fn entry -> Enum.find_index(@tiers, &(&1 == entry.tier)) end

    cond do
      tier.(left) != tier.(right) ->
        tier.(left) < tier.(right)

      left.tier == :dns and left.resource.address != right.resource.address ->
        compare_patterns(left.resource.address, right.resource.address) == :lt

      left.prefix != right.prefix ->
        left.prefix > right.prefix

      left.breadth != right.breadth ->
        left.breadth < right.breadth

      true ->
        left.resource.id >= right.resource.id
    end
  end

  defp outcome(%{allowed?: false}, _holds_device?), do: :blocked

  defp outcome(%{tier: :device_pool} = entry, holds_device?) do
    if holds_device?.(entry) do
      :reach
    else
      :refused
    end
  end

  defp outcome(_entry, _holds_device?), do: :reach

  # Within a table, a permitted entry always wins over one the filters refuse; among
  # device pools, the Client asks with every pool, so one that holds the device wins.
  defp outcome_rank(:reach), do: 0
  defp outcome_rank(:refused), do: 1
  defp outcome_rank(:blocked), do: 2

  defp allows?([], _protocol, _port), do: true
  defp allows?(filters, :icmp, _port), do: Enum.any?(filters, &(&1.protocol == :icmp))

  defp allows?(filters, protocol, port) do
    Enum.any?(filters, fn filter ->
      filter.protocol == protocol and Enum.any?(port_ranges(filter), fn {lo, hi} -> port in lo..hi end)
    end)
  end

  # connlib counts the protocol and port pairs a filter permits; no filter permits all.
  defp breadth([]), do: @permit_all

  defp breadth(filters) do
    ports = fn protocol ->
      filters
      |> Enum.filter(&(&1.protocol == protocol))
      |> Enum.flat_map(&port_ranges/1)
      |> union_size()
    end

    icmp = filters |> Enum.count(&(&1.protocol == :icmp)) |> min(1)
    ports.(:tcp) + ports.(:udp) + icmp
  end

  defp port_ranges(%{ports: ports}) when ports in [nil, []], do: [{0, 65_535}]

  defp port_ranges(%{ports: ports}) do
    Enum.flat_map(ports, fn range ->
      case range |> to_string() |> String.split("-", parts: 2) |> Enum.map(&Integer.parse(String.trim(&1))) do
        [{port, ""}] -> [{port, port}]
        [{lo, ""}, {hi, ""}] -> [{lo, hi}]
        _other -> []
      end
    end)
  end

  defp union_size(ranges) do
    ranges
    |> Enum.sort()
    |> Enum.reduce([], fn
      {lo, hi}, [{plo, phi} | rest] when lo <= phi + 1 -> [{plo, max(hi, phi)} | rest]
      range, acc -> [range | acc]
    end)
    |> Enum.reduce(0, fn {lo, hi}, sum -> sum + hi - lo + 1 end)
  end

  # connlib turns `.` into `/` and matches with a glob, so `*` and `?` stay inside one
  # label and `**` spans any number of them. `*.example.com` also matches `example.com`.
  defp pattern_matches?(pattern, domain) do
    pattern = String.downcase(pattern)

    apex? =
      case pattern do
        "*." <> rest -> rest == domain
        _other -> false
      end

    apex? or Regex.match?(pattern_regex(pattern), domain)
  end

  defp pattern_regex(pattern) do
    labels = String.split(pattern, ".")
    last = length(labels) - 1

    source =
      labels
      |> Enum.with_index()
      |> Enum.map_join(fn
        {"**", index} when index < last -> "(?:[^.]+\\.)*"
        {"**", _index} -> "[^.]+(?:\\.[^.]+)*"
        {label, index} when index < last -> label_regex(label) <> "\\."
        {label, _index} -> label_regex(label)
      end)

    Regex.compile!("\\A" <> source <> "\\z")
  end

  defp label_regex(label) do
    label
    |> String.graphemes()
    |> Enum.map_join(fn
      "*" -> "[^.]*"
      "?" -> "[^.]"
      char -> Regex.escape(char)
    end)
  end

  # `:lt` means `left` is the more specific pattern. connlib compares from the right so
  # that `*.example.com` and `a.example.com` meet at their shared suffix, and puts
  # wildcards after literals.
  defp compare_patterns(left, right) do
    compare_reversed(
      left |> String.to_charlist() |> Enum.reverse(),
      right |> String.to_charlist() |> Enum.reverse()
    )
  end

  defp compare_reversed([char | left], [char | right]), do: compare_reversed(left, right)
  defp compare_reversed([?* | _left], [?? | _right]), do: :gt
  defp compare_reversed([?? | _left], [?* | _right]), do: :lt
  defp compare_reversed([wild | _left], []) when wild in @wildcards, do: :gt
  defp compare_reversed([wild | _left], [?. | _right]) when wild in @wildcards, do: :gt
  defp compare_reversed([], [wild | _right]) when wild in @wildcards, do: :lt
  defp compare_reversed([?. | _left], [wild | _right]) when wild in @wildcards, do: :lt
  defp compare_reversed([wild | _left], [_char | _right]) when wild in @wildcards, do: :gt
  defp compare_reversed([_char | _left], [wild | _right]) when wild in @wildcards, do: :lt
  defp compare_reversed([left | _left], [right | _right]) when left > right, do: :lt
  defp compare_reversed([_left | _rest], [_right | _other]), do: :gt
  defp compare_reversed([_char | _left], []), do: :gt
  defp compare_reversed([], [_char | _right]), do: :lt
  defp compare_reversed([], []), do: :eq
end
