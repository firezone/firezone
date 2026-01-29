defmodule Portal.Resource do
  use Ecto.Schema
  import Ecto.Changeset
  import Portal.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type filter :: %{
          protocol: :tcp | :udp | :icmp,
          ports: [Portal.Types.Int4Range.t()]
        }

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          address: String.t(),
          address_description: String.t() | nil,
          name: String.t(),
          type: :cidr | :ip | :dns | :internet,
          ip_stack: :ipv4_only | :ipv6_only | :dual,
          filters: [filter()],
          account_id: Ecto.UUID.t(),
          site_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "resources" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true, autogenerate: true

    field :address, :string
    field :address_description, :string
    field :name, :string

    field :type, Ecto.Enum, values: [:cidr, :ip, :dns, :internet]
    field :ip_stack, Ecto.Enum, values: [:ipv4_only, :ipv6_only, :dual]

    embeds_many :filters, Filter, on_replace: :delete, primary_key: false do
      field :protocol, Ecto.Enum, values: [tcp: 6, udp: 17, icmp: 1]
      field :ports, {:array, Portal.Types.Int4Range}, default: []
    end

    belongs_to :site, Portal.Site

    has_many :policies, Portal.Policy, references: :id
    has_many :groups, through: [:policies, :group]

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    fields = ~w[address address_description name type ip_stack site_id]a

    changeset
    |> trim_change(fields)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:address_description, min: 1, max: 512)
    |> maybe_put_default_ip_stack()
    |> validate_address_format()
    |> check_constraint(:ip_stack,
      name: :resources_ip_stack_not_null,
      message:
        "IP stack must be one of 'dual', 'ipv4_only', 'ipv6_only' for DNS resources or NULL for others"
    )
    |> cast_embed(:filters, with: &filter_changeset/2)
    |> assoc_constraint(:site)
    |> assoc_constraint(:account)
    |> unique_constraint(:name,
      name: :resources_account_id_name_index,
      message: "resource with this name already exists"
    )
    |> unique_constraint(:ipv4, name: :resources_account_id_ipv4_index)
    |> unique_constraint(:ipv6, name: :resources_account_id_ipv6_index)
    |> unique_constraint(:type,
      name: :unique_internet_resource_per_account,
      message: "Internet resource already exists for this account"
    )
  end

  defp validate_address_format(changeset) do
    if has_errors?(changeset, :type) or has_errors?(changeset, :address) do
      changeset
    else
      changeset
      |> maybe_force_address_revalidation()
      |> validate_address_has_no_port()
      |> validate_address_by_type()
    end
  end

  defp maybe_force_address_revalidation(changeset) do
    if Map.has_key?(changeset.changes, :type) do
      case fetch_field(changeset, :address) do
        {_, address} when not is_nil(address) ->
          force_change(changeset, :address, address)

        _ ->
          changeset
      end
    else
      changeset
    end
  end

  defp validate_address_by_type(changeset) do
    case fetch_field(changeset, :type) do
      {_, :dns} -> validate_dns_address(changeset)
      {_, :cidr} -> validate_cidr_address(changeset)
      {_, :ip} -> validate_ip_address(changeset)
      {_, :internet} -> put_change(changeset, :address, nil)
      _ -> changeset
    end
  end

  # TLD constants for DNS validation
  @common_tlds ~w[
    com org net edu gov mil biz info name mobi pro
    ac ad ae af ag ai al am ao ar as at au aw ax az
    ba bb bd be bf bg bh bi bj bm bn bo br bs bt bv bw by bz
    ca cc cd cf cg ch ci ck cl cm cn co cr cu cv cw cx cy cz
    de dj dk dm do dz ec ee eg er es et eu fi fj fk fm fo fr
    ga gb gd ge gf gg gh gi gl gm gn gp gq gr gt gu gw gy hk
    hm hn hr ht hu id ie il im in io iq ir is it je jm jo jp
    ke kg kh ki km kn kp kr kw ky kz la lb lc li lk lr ls lt lu lv ly
    ma mc md me mg mh mk ml mm mn mo mp mq mr ms mt mu mv mw mx my mz
    na nc ne nf ng ni nl no np nr nu nz om pa pe pf pg ph pk pl pm pn pr ps pt pw py
    qa re ro rs ru rw sa sb sc sd se sg sh si sj sk sl sm sn so sr ss st sv sx sy sz
    tc td tf tg th tj tk tl tm tn to tr tt tv tw tz ua ug uk us uy uz
    va vc ve vg vi vn vu wf ws ye yt za zm zw
  ]

  @prohibited_tlds ~w[localhost]

  defp validate_dns_address(changeset) do
    changeset
    |> validate_length(:address, min: 1, max: 253)
    |> validate_not_an_ip_address()
    |> validate_contains_only_valid_dns_characters()
    |> validate_dns_parts()
  end

  defp validate_not_an_ip_address(changeset) do
    changeset
    |> validate_change(:address, fn field, address ->
      cond do
        String.match?(address, ~r/^(\d+\.){3}\d+(\/$\d+)?$/) ->
          [{field, "IP addresses are not allowed, use an IP Resource instead"}]

        String.match?(
          address,
          ~r/^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}(\/\d+)?$|^::([0-9a-fA-F]{0,4}:){0,6}[0-9a-fA-F]{0,4}(\/\d+)?$/
        ) ->
          [{field, "IP addresses are not allowed, use an IP Resource instead"}]

        true ->
          []
      end
    end)
  end

  defp validate_contains_only_valid_dns_characters(changeset) do
    changeset
    |> validate_format(
      :address,
      ~r/^(?:[a-zA-Z0-9\p{L}*?](?:[a-zA-Z0-9\p{L}\-*?]*[a-zA-Z0-9\p{L}*?])?)(?:\.(?:[a-zA-Z0-9\p{L}*?](?:[a-zA-Z0-9\p{L}\-*?]*[a-zA-Z0-9\p{L}*?])?))*$/u,
      message:
        "must be a valid hostname (letters, digits, hyphens, dots; wildcards *, ?, ** allowed)"
    )
  end

  defp validate_dns_parts(changeset) do
    changeset
    |> validate_change(:address, fn field, dns_address ->
      parts = String.split(dns_address, ".")

      {tld, domain_parts} =
        case Enum.reverse(parts) do
          [tld | rest] -> {String.downcase(tld), rest}
          [] -> {"", []}
        end

      cond do
        Enum.any?(parts, &(String.length(&1) > 63)) ->
          [{field, "each label must not exceed 63 characters"}]

        String.contains?(tld, ["*", "?"]) ->
          [{field, "TLD cannot contain wildcards"}]

        tld in @prohibited_tlds ->
          [
            {field,
             "#{tld} cannot be used as a TLD. Try adding a DNS alias to /etc/hosts on the Gateway(s) instead"}
          ]

        Enum.any?(domain_parts, fn part -> String.contains?(part, "**") and part != "**" end) ->
          [{field, "wildcard pattern must not contain ** in the middle of a label"}]

        Enum.all?(parts, &(&1 == "*")) ->
          [{field, "wildcard pattern must include a valid domain"}]

        tld in @common_tlds and Enum.all?(domain_parts, &String.match?(&1, ~r/^[\*\?]+$/)) ->
          [{field, "domain for IANA TLDs cannot consist solely of wildcards"}]

        true ->
          []
      end
    end)
  end

  defp validate_cidr_address(changeset) do
    changeset
    |> validate_no_malformed_brackets()
    |> validate_and_normalize_cidr(:address)
    |> validate_not_full_tunnel(
      ipv4_message: "please use the Internet Resource for full-tunnel traffic",
      ipv6_message: "please use the Internet Resource for full-tunnel traffic"
    )
    |> validate_not_loopback()
    |> validate_not_in_private_range()
  end

  defp validate_ip_address(changeset) do
    changeset
    |> validate_no_malformed_brackets()
    |> validate_and_normalize_ip(:address)
    |> validate_not_full_tunnel(
      ipv4_message: "cannot contain all IPv4 addresses",
      ipv6_message: "cannot contain all IPv6 addresses"
    )
    |> validate_not_loopback()
    |> validate_not_in_private_range()
  end

  defp validate_not_full_tunnel(changeset, opts) do
    changeset
    |> validate_not_in_cidr(:address, %Postgrex.INET{address: {0, 0, 0, 0}, netmask: 32},
      message: opts[:ipv4_message]
    )
    |> validate_not_in_cidr(
      :address,
      %Postgrex.INET{address: {0, 0, 0, 0, 0, 0, 0, 0}, netmask: 128},
      message: opts[:ipv6_message]
    )
  end

  defp validate_not_loopback(changeset) do
    changeset
    |> validate_not_in_cidr(:address, %Postgrex.INET{address: {127, 0, 0, 0}, netmask: 8},
      message: "cannot contain loopback addresses"
    )
    |> validate_not_in_cidr(
      :address,
      %Postgrex.INET{address: {0, 0, 0, 0, 0, 0, 0, 1}, netmask: 128},
      message: "cannot contain loopback addresses"
    )
  end

  defp validate_not_in_private_range(changeset) do
    if has_errors?(changeset, :address) do
      changeset
    else
      address = get_field(changeset, :address)

      if address in ["0.0.0.0/0", "::/0"] do
        changeset
      else
        changeset
        |> validate_not_in_cidr(:address, Portal.IPv4Address.reserved_cidr())
        |> validate_not_in_cidr(:address, Portal.IPv6Address.reserved_cidr())
      end
    end
  end

  defp validate_address_has_no_port(changeset) do
    validate_change(changeset, :address, fn :address, address ->
      cond do
        # Bracketed IPv6 with port: [2001:db8::1]:8080
        String.match?(address, ~r/\]:\d+$/) ->
          [{:address, "cannot contain a port number"}]

        # Single colon indicates a port (e.g., example.com:8080, 192.168.1.1:8080)
        # IPv6 addresses have multiple colons so they're allowed
        String.contains?(address, ":") and not String.match?(address, ~r/:.*:/) ->
          [{:address, "cannot contain a port number"}]

        true ->
          []
      end
    end)
  end

  defp validate_no_malformed_brackets(changeset) do
    validate_change(changeset, :address, fn :address, address ->
      has_open = String.contains?(address, "[")
      has_close = String.contains?(address, "]")

      if has_open != has_close do
        [{:address, "has mismatched brackets"}]
      else
        []
      end
    end)
  end

  defp maybe_put_default_ip_stack(changeset) do
    current_type = get_field(changeset, :type)
    original_type = Map.get(changeset.data, :type, nil)

    cond do
      current_type == :dns ->
        put_default_value(changeset, :ip_stack, :dual)

      original_type == :dns and current_type != :dns ->
        put_change(changeset, :ip_stack, nil)

      true ->
        changeset
    end
  end

  defp filter_changeset(struct, attrs) do
    struct
    |> cast(attrs, [:protocol, :ports])
    |> validate_required([:protocol])
  end

  # Utility functions moved from Portal.Resources

  @doc """
    This does two things:
    1. Filters out resources that are not compatible with the given client or gateway version.
    2. Converts DNS resource addresses back to the pre-1.2.0 format if the client or gateway version is < 1.2.0.
  """
  def adapt_resource_for_version(resource, client_or_gateway_version) do
    cond do
      # internet resources require client and gateway >= 1.3.0
      resource.type == :internet and Version.match?(client_or_gateway_version, "< 1.3.0") ->
        nil

      # non-internet resource, pass as-is
      Version.match?(client_or_gateway_version, ">= 1.2.0") ->
        resource

      # we need convert dns resource addresses back to pre-1.2.0 format
      true ->
        resource.address
        |> String.codepoints()
        |> map_resource_address()
        |> case do
          {:cont, address} -> %{resource | address: address}
          :drop -> nil
        end
    end
  end

  defp map_resource_address(address, acc \\ "")

  defp map_resource_address(["*", "*" | rest], ""),
    do: map_resource_address(rest, "*")

  defp map_resource_address(["*", "*" | _rest], _acc),
    do: :drop

  defp map_resource_address(["*" | rest], ""),
    do: map_resource_address(rest, "?")

  defp map_resource_address(["*" | _rest], _acc),
    do: :drop

  defp map_resource_address(["?" | _rest], _acc),
    do: :drop

  defp map_resource_address([char | rest], acc),
    do: map_resource_address(rest, acc <> char)

  defp map_resource_address([], acc),
    do: {:cont, acc}
end
