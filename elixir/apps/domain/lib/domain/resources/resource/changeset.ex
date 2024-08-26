defmodule Domain.Resources.Resource.Changeset do
  use Domain, :changeset
  alias Domain.{Auth, Accounts, Network}
  alias Domain.Resources.{Resource, Connection}

  @fields ~w[address address_description name type]a
  @update_fields ~w[name address_description]a
  @required_fields ~w[name address type]a

  # This list is based on the list of TLDs from the IANA but only contains
  # all the country zones and most common generic zones.
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

  @prohibited_tlds ~w[
    localhost
  ]

  def create(%Accounts.Account{} = account, attrs, %Auth.Subject{} = subject) do
    %Resource{connections: []}
    |> cast(attrs, @fields)
    |> changeset()
    |> validate_required(@required_fields)
    |> put_change(:account_id, account.id)
    |> update_change(:address, &String.trim/1)
    |> validate_address()
    |> cast_assoc(:connections,
      with: &Connection.Changeset.changeset(account.id, &1, &2, subject),
      required: true
    )
    |> put_created_by(subject)
  end

  def create(%Accounts.Account{} = account, attrs) do
    %Resource{connections: []}
    |> cast(attrs, @fields)
    |> changeset()
    |> validate_required(@required_fields)
    |> validate_address()
    |> cast_assoc(:connections,
      with: &Connection.Changeset.changeset(account.id, &1, &2)
    )
  end

  defp validate_address(changeset) do
    if has_errors?(changeset, :type) do
      changeset
    else
      case fetch_field(changeset, :type) do
        {_data_or_changes, :dns} ->
          validate_dns_address(changeset)

        {_data_or_changes, :cidr} ->
          validate_cidr_address(changeset)

        {_data_or_changes, :ip} ->
          validate_ip_address(changeset)

        _other ->
          changeset
      end
    end
  end

  defp validate_dns_address(changeset) do
    changeset
    |> validate_length(:address, min: 1, max: 253)
    |> validate_format(:address, ~r/^[\p{L}\*\?0-9-]{1,63}(\.[\p{L}\*\?0-9-]{1,63})*$/iu)
    |> validate_change(:address, fn field, dns_address ->
      {tld, domain} =
        dns_address
        |> String.split(".")
        |> Enum.reverse()
        |> case do
          [tld, domain | _rest] -> {String.downcase(tld), String.downcase(domain)}
          [tld | _rest] -> {String.downcase(tld), ""}
          [] -> {"", ""}
        end

      cond do
        String.contains?(tld, ["*", "?"]) ->
          [{field, {"TLD cannot contain wildcards", []}}]

        tld in @prohibited_tlds ->
          [
            {field,
             {"#{tld} cannot be used as a TLD. " <>
                "Try adding a DNS alias to /etc/hosts on the Gateway(s) instead", []}}
          ]

        tld in @common_tlds and String.contains?(domain, ["*", "?"]) ->
          [{field, {"second level domain for IANA TLDs cannot contain wildcards", []}}]

        true ->
          []
      end
    end)
  end

  defp validate_cidr_address(changeset) do
    changeset
    |> validate_and_normalize_cidr(:address)
    |> validate_not_in_cidr(:address, %Postgrex.INET{address: {0, 0, 0, 0}, netmask: 32},
      message: "cannot contain all IPv4 addresses"
    )
    |> validate_not_in_cidr(:address, %Postgrex.INET{address: {127, 0, 0, 0}, netmask: 8},
      message: "cannot contain loopback addresses"
    )
    |> validate_not_in_cidr(
      :address,
      %Postgrex.INET{
        address: {0, 0, 0, 0, 0, 0, 0, 0},
        netmask: 128
      },
      message: "cannot contain all IPv6 addresses"
    )
    |> validate_not_in_cidr(
      :address,
      %Postgrex.INET{
        address: {0, 0, 0, 0, 0, 0, 0, 1},
        netmask: 128
      },
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
      %Postgrex.INET{
        address: {0, 0, 0, 0, 0, 0, 0, 0},
        netmask: 128
      },
      message: "cannot contain all IPv6 addresses"
    )
    |> validate_not_in_cidr(
      :address,
      %Postgrex.INET{
        address: {0, 0, 0, 0, 0, 0, 0, 1},
        netmask: 128
      },
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

  def update(%Resource{} = resource, attrs, %Auth.Subject{} = subject) do
    resource
    |> cast(attrs, @update_fields)
    |> validate_required(@required_fields)
    |> changeset()
    |> cast_assoc(:connections,
      with: &Connection.Changeset.changeset(resource.account_id, &1, &2, subject),
      required: true
    )
  end

  defp changeset(changeset) do
    changeset
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:address_description, min: 1, max: 512)
    |> cast_embed(:filters, with: &cast_filter/2)
    |> unique_constraint(:ipv4, name: :resources_account_id_ipv4_index)
    |> unique_constraint(:ipv6, name: :resources_account_id_ipv6_index)
  end

  def delete(%Resource{} = resource) do
    resource
    |> change()
    |> put_default_value(:deleted_at, DateTime.utc_now())
  end

  defp cast_filter(%Resource.Filter{} = filter, attrs) do
    filter
    |> cast(attrs, [:protocol, :ports])
    |> validate_required([:protocol])
  end
end
