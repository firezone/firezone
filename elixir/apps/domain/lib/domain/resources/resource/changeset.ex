defmodule Domain.Resources.Resource.Changeset do
  use Domain, :changeset
  alias Domain.{Auth, Accounts, Network}
  alias Domain.Resources.{Resource, Connection}

  @fields ~w[address address_description name type ip_stack]a
  @update_fields ~w[address address_description name type ip_stack]a
  @replace_fields ~w[type address filters ip_stack]a
  @required_fields ~w[name type]a

  # Reference list of common TLDs from IANA
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

  def create(%Accounts.Account{} = account, attrs, %Auth.Subject{} = subject) do
    %Resource{connections: []}
    |> cast(attrs, @fields)
    |> changeset()
    |> validate_required(@required_fields)
    |> put_change(:persistent_id, Ecto.UUID.generate())
    |> put_change(:account_id, account.id)
    |> update_change(:address, &String.trim/1)
    |> validate_address(account)
    |> cast_assoc(:connections,
      with: &Connection.Changeset.changeset(account.id, &1, &2, subject),
      required: true
    )
    |> put_subject_trail(:created_by, subject)
  end

  def create(%Accounts.Account{} = account, attrs) do
    %Resource{connections: []}
    |> cast(attrs, @fields)
    |> changeset()
    |> validate_required(@required_fields)
    |> update_change(:address, &String.trim/1)
    |> validate_address(account)
    |> put_change(:persistent_id, Ecto.UUID.generate())
    |> put_change(:account_id, account.id)
    |> put_subject_trail(:created_by, :system)
    |> cast_assoc(:connections,
      with: &Connection.Changeset.changeset(account.id, &1, &2)
    )
  end

  def update(%Resource{} = resource, attrs, %Auth.Subject{} = subject) do
    resource
    |> cast(attrs, @update_fields)
    |> validate_required(@required_fields)
    |> validate_address(subject.account)
    |> changeset()
    |> cast_assoc(:connections,
      with: &Connection.Changeset.changeset(resource.account_id, &1, &2, subject),
      required: true
    )
    |> maybe_breaking_change()
  end

  def delete(%Resource{} = resource) do
    resource
    |> change()
    |> put_default_value(:deleted_at, DateTime.utc_now())
  end

  defp validate_address(changeset, account) do
    if has_errors?(changeset, :type) do
      changeset
    else
      # Force address revalidation if type has changed
      changeset =
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

      case fetch_field(changeset, :type) do
        {_data_or_changes, :dns} ->
          changeset
          |> validate_required(:address)
          |> validate_dns_address()

        {_data_or_changes, :cidr} ->
          changeset
          |> validate_required(:address)
          |> validate_cidr_address(account)

        {_data_or_changes, :ip} ->
          changeset
          |> validate_required(:address)
          |> validate_ip_address()

        {_data_or_changes, :internet} ->
          put_change(changeset, :address, nil)

        _other ->
          changeset
      end
    end
  end

  defp validate_dns_address(changeset) do
    changeset
    |> validate_length(:address, min: 1, max: 253)
    |> validate_not_an_ip_address()
    |> validate_contains_only_valid_dns_characters()
    |> validate_position_of_double_wildcard()
    |> validate_dns_parts()
  end

  defp validate_not_an_ip_address(changeset) do
    changeset
    |> validate_change(:address, fn field, address ->
      cond do
        String.match?(address, ~r/^(\d+\.){3}\d+(\/\d+)?$/) ->
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

  defp validate_position_of_double_wildcard(changeset) do
    changeset
    |> validate_change(:address, fn field, dns_address ->
      if String.contains?(dns_address, "**") and
           not (String.starts_with?(dns_address, "**.") or String.contains?(dns_address, ".**.")) do
        [
          {field,
           "Double wildcard (**) can only replace entire subdomains (e.g. **.example.com, sub.**.example.com)"}
        ]
      else
        []
      end
    end)
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

        Enum.all?(parts, &(&1 == "*")) ->
          [{field, "wildcard pattern must include a valid domain"}]

        tld in @common_tlds and Enum.all?(domain_parts, &String.match?(&1, ~r/^[\*\?]+$/)) ->
          [{field, "domain for IANA TLDs cannot consist solely of wildcards"}]

        true ->
          []
      end
    end)
  end

  defp validate_cidr_address(changeset, account) do
    internet_resource_message =
      if Accounts.internet_resource_enabled?(account) do
        "the Internet Resource is already created in your account. Define a Policy for it instead"
      else
        "routing all traffic through Firezone is available on paid plans using the Internet Resource"
      end

    changeset
    |> validate_and_normalize_cidr(:address)
    |> validate_not_in_cidr(:address, %Postgrex.INET{address: {0, 0, 0, 0}, netmask: 32},
      message: internet_resource_message
    )
    |> validate_not_in_cidr(:address, %Postgrex.INET{address: {127, 0, 0, 0}, netmask: 8},
      message: "cannot contain loopback addresses"
    )
    |> validate_not_in_cidr(
      :address,
      %Postgrex.INET{address: {0, 0, 0, 0, 0, 0, 0, 0}, netmask: 128},
      message: internet_resource_message
    )
    |> validate_not_in_cidr(
      :address,
      %Postgrex.INET{address: {0, 0, 0, 0, 0, 0, 0, 1}, netmask: 128},
      message: "cannot contain loopback addresses"
    )
    |> validate_address_is_not_in_private_range()
  end

  defp validate_ip_address(changeset) do
    changeset
    |> validate_and_normalize_ip(:address)
    |> validate_not_in_cidr(:address, %Postgrex.INET{address: {0, 0, 0, 0}, netmask: 32},
      message: "cannot contain all IPv4 addresses"
    )
    |> validate_not_in_cidr(:address, %Postgrex.INET{address: {127, 0, 0, 0}, netmask: 8},
      message: "cannot contain loopback addresses"
    )
    |> validate_not_in_cidr(
      :address,
      %Postgrex.INET{address: {0, 0, 0, 0, 0, 0, 0, 0}, netmask: 128},
      message: "cannot contain all IPv6 addresses"
    )
    |> validate_not_in_cidr(
      :address,
      %Postgrex.INET{address: {0, 0, 0, 0, 0, 0, 0, 1}, netmask: 128},
      message: "cannot contain loopback addresses"
    )
    |> validate_address_is_not_in_private_range()
  end

  defp validate_address_is_not_in_private_range(changeset) do
    cond do
      has_errors?(changeset, :address) ->
        changeset

      get_field(changeset, :address) == "0.0.0.0/0" ->
        changeset

      get_field(changeset, :address) == "::/0" ->
        changeset

      true ->
        Network.reserved_cidrs()
        |> Enum.reduce(changeset, fn {_type, cidr}, changeset ->
          validate_not_in_cidr(changeset, :address, cidr)
        end)
    end
  end

  defp maybe_breaking_change(%{valid?: false} = changeset), do: {changeset, false}

  defp maybe_breaking_change(changeset) do
    if any_field_changed?(changeset, @replace_fields) do
      {changeset, true}
    else
      {changeset, false}
    end
  end

  defp changeset(changeset) do
    changeset
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:address_description, min: 1, max: 512)
    |> maybe_put_default_ip_stack()
    |> check_constraint(:ip_stack,
      name: :resources_ip_stack_not_null,
      message:
        "IP stack must be one of 'dual', 'ipv4_only', 'ipv6_only' for DNS resources or NULL for others"
    )
    |> cast_embed(:filters, with: &cast_filter/2)
    |> unique_constraint(:ipv4, name: :resources_account_id_ipv4_index)
    |> unique_constraint(:ipv6, name: :resources_account_id_ipv6_index)
    |> unique_constraint(:type, name: :unique_internet_resource_per_account)
  end

  defp cast_filter(%Resource.Filter{} = filter, attrs) do
    filter
    |> cast(attrs, [:protocol, :ports])
    |> validate_required([:protocol])
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
end
