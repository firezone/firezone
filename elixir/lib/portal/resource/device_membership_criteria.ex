defmodule Portal.Resource.DeviceMembershipCriteria do
  @moduledoc """
  The criteria a device pool uses to decide which devices it holds, stored as JSON in
  `resources.device_membership_criteria`.

  It is one leaf that compares a device column against a literal or an attribute of
  the subject asking for access. Wire shapes:

      {"device": {"field": "id", "op": "in", "value": ["<device id>", ...]}}
      {"device": {"field": "actor_id", "op": "eq", "value": {"subject": "actor_id"}}}

  The top-level key names where the field lives (`device` is the devices table), so
  other sources, combinators and values can be added later without changing stored
  criteria.
  """
  use Ecto.Type

  alias Portal.Authentication.Subject

  @type t :: %__MODULE__{
          provider: :device,
          field: :id | :actor_id,
          op: :in | :eq,
          value: {:literal, [Ecto.UUID.t()]} | {:subject, :actor_id}
        }

  defstruct [:provider, :field, :op, :value]

  @subject_attrs %{"actor_id" => :actor_id}

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

  @doc "The device ids of criteria that list their devices, `:error` for any other criteria."
  @spec device_ids(t() | nil) :: {:ok, [Ecto.UUID.t()]} | :error
  def device_ids(%__MODULE__{field: :id, op: :in, value: {:literal, device_ids}}), do: {:ok, device_ids}
  def device_ids(_criteria), do: :error

  @doc "Whether `device` is in a pool with these criteria when `subject` asks."
  @spec member?(t(), Portal.Device.t(), Subject.t()) :: boolean()
  def member?(%__MODULE__{provider: :device, field: field, op: :in, value: {:literal, values}}, device, _subject) do
    Map.fetch!(device, field) in values
  end

  def member?(%__MODULE__{provider: :device, field: field, op: :eq, value: value}, device, subject) do
    Map.fetch!(device, field) == resolve_value(value, subject)
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
    with {:ok, value} <- parse_subject_value(value) do
      {:ok, %__MODULE__{provider: :device, field: :actor_id, op: :eq, value: value}}
    end
  end

  defp parse(_map), do: :error

  defp parse_subject_value(%{"subject" => attr} = value) when map_size(value) == 1 do
    with {:ok, attr} <- Map.fetch(@subject_attrs, attr) do
      {:ok, {:subject, attr}}
    end
  end

  defp parse_subject_value(_value), do: :error

  defp resolve_value({:subject, :actor_id}, %Subject{actor: %{id: actor_id}}), do: actor_id

  defp normalize_ids(device_ids), do: device_ids |> Enum.uniq() |> Enum.sort()
end
