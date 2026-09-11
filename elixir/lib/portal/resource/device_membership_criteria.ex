defmodule Portal.Resource.DeviceMembershipCriteria do
  @moduledoc """
  The criteria a dynamic device pool uses to decide which devices it holds, stored as
  JSON in `resources.device_membership_criteria`.

  It is one leaf that compares a device column against an attribute of the
  subject asking for access. Wire shape:

      {"device": {"field": "actor_id", "op": "eq", "value": {"subject": "actor_id"}}}

  The top-level key names where the field lives (`device` is the devices table), so
  other sources, combinators and literal values can be added later without changing
  stored criteria.
  """
  use Ecto.Type

  alias Portal.Authentication.Subject

  @type t :: %__MODULE__{
          provider: :device,
          field: :actor_id,
          op: :eq,
          value: {:subject, :actor_id}
        }

  defstruct [:provider, :field, :op, :value]

  @fields %{"device" => %{"actor_id" => :actor_id}}
  @ops %{"eq" => :eq}
  @subject_attrs %{"actor_id" => :actor_id}

  @doc "The criteria that hold the devices of the actor asking."
  @spec own_devices() :: t()
  def own_devices do
    %__MODULE__{provider: :device, field: :actor_id, op: :eq, value: {:subject, :actor_id}}
  end

  @doc "Whether `device` is in a pool with these criteria when `subject` asks."
  @spec member?(t(), Portal.Device.t(), Subject.t()) :: boolean()
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
  def to_map(%__MODULE__{provider: provider, field: field, op: op, value: {:subject, attr}}) do
    %{
      Atom.to_string(provider) => %{
        "field" => Atom.to_string(field),
        "op" => Atom.to_string(op),
        "value" => %{"subject" => Atom.to_string(attr)}
      }
    }
  end

  defp parse(%{"device" => %{"field" => field, "op" => op, "value" => value} = leaf} = map)
       when map_size(map) == 1 and map_size(leaf) == 3 do
    with {:ok, field} <- Map.fetch(@fields["device"], field),
         {:ok, op} <- Map.fetch(@ops, op),
         {:ok, value} <- parse_value(value) do
      {:ok, %__MODULE__{provider: :device, field: field, op: op, value: value}}
    else
      :error -> :error
    end
  end

  defp parse(_map), do: :error

  defp parse_value(%{"subject" => attr} = value) when map_size(value) == 1 do
    with {:ok, attr} <- Map.fetch(@subject_attrs, attr) do
      {:ok, {:subject, attr}}
    end
  end

  defp parse_value(_value), do: :error

  defp resolve_value({:subject, :actor_id}, %Subject{actor: %{id: actor_id}}), do: actor_id
end
