defmodule FzHttp.Devices.Device.Query do
  use FzHttp, :query

  def all do
    from(devices in FzHttp.Devices.Device, as: :devices)
  end

  def by_id(queryable \\ all(), id) do
    where(queryable, [devices: devices], devices.id == ^id)
  end

  def by_user_id(queryable \\ all(), user_id) do
    where(queryable, [devices: devices], devices.user_id == ^user_id)
  end

  def by_latest_handshake_seconds_ago(queryable \\ all(), seconds_ago) do
    where(
      queryable,
      [devices: devices],
      devices.latest_handshake > from_now(-1 * ^seconds_ago, "second")
    )
  end

  def only_active(queryable \\ all()) do
    dynamic =
      if FzHttp.Config.vpn_sessions_expire?() do
        vpn_session_duration = FzHttp.Config.fetch_config!(:vpn_session_duration)

        dynamic(
          [user: user],
          is_nil(user.last_signed_in_at) or
            user.last_signed_in_at < from_now(^vpn_session_duration, "second")
        )
      else
        true
      end

    queryable
    |> with_preloaded_user()
    |> where([user: user], is_nil(user.disabled_at))
    |> where([user: user], ^dynamic)
  end

  def group_by_user_id(queryable \\ all()) do
    queryable
    |> group_by([devices: devices], devices.user_id)
  end

  def select_max_count(queryable \\ all()) do
    queryable
    |> select([devices: devices], count())
    |> order_by([devices: devices], desc: count())
    |> limit(1)
  end

  def with_preloaded_user(queryable \\ all()) do
    with_named_binding(queryable, :user, fn queryable, binding ->
      queryable
      |> join(:inner, [devices: devices], user in assoc(devices, ^binding), as: ^binding)
      |> preload([devices: devices, user: user], user: user)
    end)
  end

  @doc """
  Returns IP address at given integer offset relative to start of CIDR range.
  """
  defmacro offset_to_ip(field, cidr) do
    quote do
      fragment("host(?)::inet + ?", unquote(cidr), unquote(field))
    end
  end

  @doc """
  Returns index of last IP address available for allocation in CIDR sequence.

  Notice: the very last address in CIDR is typically a broadcast address that we won't allow to use for devices.
  """
  defmacro cidr_end_offset(cidr) do
    quote do
      fragment(
        "host(broadcast(?))::inet - host(?)::inet - 1",
        unquote(cidr),
        unquote(cidr)
      )
    end
  end

  @doc """
  Acquires a transactional advisory lock for an IP address using "devices" table oid as namespace.

  To fit bigint offset into int lock identifier we rollover at the integer max value.
  """
  defmacro acquire_advisory_lock(field) do
    quote do
      fragment(
        "pg_try_advisory_xact_lock('devices'::regclass::oid::int, mod(?, 2147483647)::int)",
        unquote(field)
      )
    end
  end

  @doc """
  This function returns a query to fetch next available IP address, it works in 2 steps:

  1. It starts by forward-scanning starting for available addresses at `offset` in a given `network_cidr`
  up to the end of CIDR range;

  2. If forward-scan failed, scan backwards from the offset (exclusive) to start of CIDR range.

  During the search, addresses occupied by other devices or reserved are skipped.

  We also exclude first (X.X.X.0) and last (broadcast) address in a CIDR from a search range,
  to prevent issues with legacy firewalls that consider them "class C" space network addresses.
  """
  def next_available_address(network_cidr, offset, reserved_address) do
    forward_search_queryable =
      series_from_offset_inclusive_to_end_of_cidr(network_cidr, offset)
      |> select_not_used_ips(network_cidr, reserved_address)

    reverse_search_queryable =
      series_from_start_of_cidr_to_offset_exclusive(network_cidr, offset)
      |> select_not_used_ips(network_cidr, reserved_address)

    union_all(forward_search_queryable, ^reverse_search_queryable)
    |> limit(1)
  end

  # Although sequences can work with inet types, we iterate over the sequence using an
  # offset relative to start of the given CIDR range.
  #
  # This way is chosen because IPv6 cannot be cast to bigint, so by using it directly
  # we won't be able to increment/decrement it while building a sequence.
  #
  # At the same time offset will fit to bigint even for largest CIDR ranges that Firezone supports.
  #
  # XXX: We can make this code prettier once https://github.com/elixir-ecto/ecto/commit/8f7bb2665bce30dfab18cfed01585c96495575a6 is released.
  defp series_from_offset_inclusive_to_end_of_cidr(network_cidr, offset) do
    from(
      i in fragment(
        "SELECT generate_series((?)::bigint, (?)::bigint, ?) AS ip",
        ^offset,
        cidr_end_offset(^network_cidr),
        1
      ),
      as: :q
    )
  end

  defp series_from_start_of_cidr_to_offset_exclusive(_network_cidr, offset) do
    from(
      i in fragment(
        "SELECT generate_series((?)::bigint, (?)::bigint, ?) AS ip",
        ^(offset - 1),
        2,
        -1
      ),
      as: :q
    )
  end

  defp select_not_used_ips(queryable, network_cidr, reserved_ips) do
    host_as_string = network_cidr.address |> :inet.ntoa() |> List.to_string()

    queryable
    |> where(
      [q: q],
      offset_to_ip(q.ip, ^network_cidr) not in subquery(used_ips_subquery(network_cidr))
    )
    |> where([q: q], offset_to_ip(q.ip, ^network_cidr) not in ^reserved_ips)
    |> where(
      [q: q],
      acquire_advisory_lock(fragment("hashtext(?) + ?", ^host_as_string, q.ip)) ==
        true
    )
    |> select([q: q], offset_to_ip(q.ip, ^network_cidr))
  end

  defp used_ips_subquery(queryable \\ all(), address)

  defp used_ips_subquery(queryable, %Postgrex.INET{address: address})
       when tuple_size(address) == 4 do
    select(queryable, [devices: devices], devices.ipv4)
  end

  defp used_ips_subquery(queryable, %Postgrex.INET{address: _address}) do
    select(queryable, [devices: devices], devices.ipv6)
  end
end
