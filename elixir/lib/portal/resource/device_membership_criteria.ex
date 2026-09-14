defmodule Portal.Resource.DeviceMembershipCriteria do
  @moduledoc """
  The criteria a device pool uses to decide which devices it holds, stored as JSON in
  `resources.device_membership_criteria`.

  It is one leaf that compares a column against a literal or an attribute of the
  subject asking for access. Wire shapes:

      {"device": {"field": "id", "op": "in", "value": ["<device id>", ...]}}
      {"device": {"field": "actor_id", "op": "eq", "value": {"subject": "actor_id"}}}
      {"device": {"field": "account_id", "op": "eq", "value": {"subject": "account_id"}}}
      {"actor_group": {"field": "id", "op": "eq", "value": "<group id>"}}

  The top-level key names where the field lives: `device` is the devices table and
  `actor_group` the groups the device's actor is a member of. Other sources,
  combinators and values can be added later without changing stored criteria.
  """
  use Ecto.Type
  import Ecto.Query

  alias __MODULE__.Database
  alias Portal.Authentication.Subject

  @type provider :: :device | :actor_group
  @type field :: :id | :actor_id | :account_id
  @type value :: {:literal, [Ecto.UUID.t()] | Ecto.UUID.t()} | {:subject, :actor_id | :account_id}

  @type t :: %__MODULE__{provider: provider(), field: field(), op: :in | :eq, value: value()}

  @typedoc "Which devices the criteria pick: the same for everyone, or one actor's."
  @type scope :: :all | {:actor, Ecto.UUID.t()}

  @typedoc "The kinds of criteria the portal knows how to build."
  @type kind :: :listed | :own_devices | :all_devices | :actor_group

  defstruct [:provider, :field, :op, :value]

  @subject_attrs %{"actor_id" => :actor_id, "account_id" => :account_id}

  @doc "The criteria that hold every client device in the account."
  @spec all_devices() :: t()
  def all_devices do
    %__MODULE__{provider: :device, field: :account_id, op: :eq, value: {:subject, :account_id}}
  end

  @doc "The criteria that hold the devices of the actor asking."
  @spec own_devices() :: t()
  def own_devices do
    %__MODULE__{provider: :device, field: :actor_id, op: :eq, value: {:subject, :actor_id}}
  end

  @doc "The criteria that hold exactly the given devices."
  @spec devices([Ecto.UUID.t()]) :: t()
  def devices(device_ids) when is_list(device_ids) do
    %__MODULE__{provider: :device, field: :id, op: :in, value: {:literal, normalize_ids(device_ids)}}
  end

  @doc "The criteria that hold the devices of every actor in the group."
  @spec actor_group(Ecto.UUID.t()) :: t()
  def actor_group(group_id) when is_binary(group_id) do
    %__MODULE__{provider: :actor_group, field: :id, op: :eq, value: {:literal, group_id}}
  end

  @doc "The kind of criteria, for code that offers the kinds the portal can build."
  @spec kind(t()) :: kind()
  def kind(%__MODULE__{provider: :device, field: :id, op: :in}), do: :listed
  def kind(%__MODULE__{provider: :device, field: :actor_id, value: {:subject, :actor_id}}), do: :own_devices
  def kind(%__MODULE__{provider: :device, field: :account_id, value: {:subject, :account_id}}), do: :all_devices
  def kind(%__MODULE__{provider: :actor_group, field: :id, op: :eq}), do: :actor_group

  @doc "The device ids of criteria that list their devices, `:error` for any other criteria."
  @spec device_ids(t() | nil) :: {:ok, [Ecto.UUID.t()]} | :error
  def device_ids(%__MODULE__{field: :id, op: :in, value: {:literal, device_ids}}), do: {:ok, device_ids}
  def device_ids(_criteria), do: :error

  @doc "The group id of criteria that hold a group's devices, `:error` for any other criteria."
  @spec group_id(t() | nil) :: {:ok, Ecto.UUID.t()} | :error
  def group_id(%__MODULE__{provider: :actor_group, field: :id, op: :eq, value: {:literal, group_id}}),
    do: {:ok, group_id}

  def group_id(_criteria), do: :error

  @doc "Whose devices the criteria pick when `subject` asks."
  @spec scope(t(), Subject.t()) :: scope()
  def scope(%__MODULE__{value: {:subject, :actor_id}}, %Subject{actor: %{id: actor_id}}), do: {:actor, actor_id}
  def scope(%__MODULE__{}, _subject), do: :all

  @doc "Whether the criteria pick one actor's devices rather than the same set for everyone."
  @spec per_actor?(t()) :: boolean()
  def per_actor?(%__MODULE__{value: {:subject, :actor_id}}), do: true
  def per_actor?(%__MODULE__{}), do: false

  @doc """
  Whether `device` is in a pool with these criteria when `subject` asks.

  `device` is a row, or a map with the same `id`, `actor_id` and `account_id` plus the
  actor's `group_ids`, as a client's presence carries them, so the answer needs no query.
  """
  @spec member?(t(), Portal.Device.t() | map(), Subject.t()) :: boolean()
  def member?(%__MODULE__{provider: :device, field: field, op: :in, value: {:literal, values}}, device, _subject) do
    Map.fetch!(device, field) in values
  end

  def member?(%__MODULE__{provider: :device, field: field, op: :eq, value: value}, device, subject) do
    Map.fetch!(device, field) == resolve_value(value, subject)
  end

  def member?(%__MODULE__{provider: :actor_group, value: {:literal, group_id}}, %{group_ids: group_ids}, _subject)
      when is_list(group_ids) do
    group_id in group_ids
  end

  def member?(%__MODULE__{provider: :actor_group} = criteria, %Portal.Device{} = device, subject) do
    Database.member?(criteria, device, subject)
  end

  @doc """
  Limits a query over the devices table, bound as `:devices`, to the members.

  The query must already be limited to one account; `scope` is the one `scope/2`
  returned for the subject asking.
  """
  @spec where_members(Ecto.Query.t(), t(), scope()) :: Ecto.Query.t()
  def where_members(query, %__MODULE__{provider: :device, field: :id, op: :in, value: {:literal, ids}}, _scope) do
    where(query, [devices: d], d.id in ^ids)
  end

  def where_members(query, %__MODULE__{provider: :device, field: :actor_id, value: {:subject, :actor_id}}, {:actor, actor_id}) do
    where(query, [devices: d], d.actor_id == ^actor_id)
  end

  def where_members(query, %__MODULE__{provider: :device, field: :account_id, value: {:subject, :account_id}}, :all) do
    query
  end

  def where_members(query, %__MODULE__{provider: :actor_group, field: :id, op: :eq, value: {:literal, group_id}}, :all) do
    where(
      query,
      [devices: d],
      exists(
        from(m in Portal.Membership,
          where:
            m.account_id == parent_as(:devices).account_id and
              m.actor_id == parent_as(:devices).actor_id and
              m.group_id == ^group_id
        )
      )
    )
  end

  @impl Ecto.Type
  def type, do: :map

  @impl Ecto.Type
  def cast(%__MODULE__{} = criteria), do: {:ok, criteria}
  def cast(%{} = map), do: parse(map)
  def cast(_other), do: :error

  @impl Ecto.Type
  def load(%{} = map), do: parse(map)

  @impl Ecto.Type
  def dump(%__MODULE__{} = criteria), do: {:ok, to_map(criteria)}
  def dump(_other), do: :error

  @impl Ecto.Type
  def embed_as(_format), do: :dump

  @doc "The wire shape of the criteria."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{provider: provider, field: field, op: op, value: value}) do
    %{
      Atom.to_string(provider) => %{
        "field" => Atom.to_string(field),
        "op" => Atom.to_string(op),
        "value" => value_to_map(value)
      }
    }
  end

  defp value_to_map({:literal, values}), do: values
  defp value_to_map({:subject, attr}), do: %{"subject" => Atom.to_string(attr)}

  defp parse(%{"device" => %{"field" => "id", "op" => "in", "value" => values} = leaf} = map)
       when map_size(map) == 1 and map_size(leaf) == 3 and is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case Ecto.UUID.cast(value) do
        {:ok, id} -> {:cont, {:ok, [id | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, devices(ids)}
      :error -> :error
    end
  end

  defp parse(%{"device" => %{"field" => "actor_id", "op" => "eq", "value" => value} = leaf} = map)
       when map_size(map) == 1 and map_size(leaf) == 3 do
    case parse_subject_value(value) do
      {:ok, {:subject, :actor_id}} -> {:ok, own_devices()}
      _other -> :error
    end
  end

  defp parse(%{"device" => %{"field" => "account_id", "op" => "eq", "value" => value} = leaf} = map)
       when map_size(map) == 1 and map_size(leaf) == 3 do
    case parse_subject_value(value) do
      {:ok, {:subject, :account_id}} -> {:ok, all_devices()}
      _other -> :error
    end
  end

  defp parse(%{"actor_group" => %{"field" => "id", "op" => "eq", "value" => value} = leaf} = map)
       when map_size(map) == 1 and map_size(leaf) == 3 do
    with {:ok, group_id} <- Ecto.UUID.cast(value) do
      {:ok, actor_group(group_id)}
    end
  end

  defp parse(_map), do: :error

  defp parse_subject_value(%{"subject" => attr} = value) when map_size(value) == 1 do
    case Map.fetch(@subject_attrs, attr) do
      {:ok, attr} -> {:ok, {:subject, attr}}
      :error -> :error
    end
  end

  defp parse_subject_value(_value), do: :error

  defp resolve_value({:subject, :actor_id}, %Subject{actor: %{id: actor_id}}), do: actor_id
  defp resolve_value({:subject, :account_id}, %Subject{account: %{id: account_id}}), do: account_id

  defp normalize_ids(device_ids), do: device_ids |> Enum.uniq() |> Enum.sort()

  defmodule Database do
    @moduledoc false
    import Ecto.Query

    alias Portal.Resource.DeviceMembershipCriteria
    alias Portal.Safe

    def member?(criteria, %Portal.Device{} = device, subject) do
      from(d in Portal.Device, as: :devices)
      |> where([devices: d], d.account_id == ^subject.account.id and d.id == ^device.id)
      |> DeviceMembershipCriteria.where_members(criteria, :all)
      |> Safe.unscoped()
      |> Safe.exists?()
    end
  end
end
