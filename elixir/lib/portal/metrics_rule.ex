defmodule Portal.MetricsRule do
  @moduledoc """
  Metric name patterns that the Clients and Gateways whose attributes contain
  all of `match` export until `expires_at`. A device exports the union of the
  patterns of its rules, at the shortest export interval they set, and labelled
  with the device if any of them targets a single device or actor.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias __MODULE__.Database

  @type t :: %__MODULE__{}

  @attributes ~w[plan account_id actor_id device_id device_type]

  # The shortest interval Clients and Gateways accept.
  @min_export_interval_secs 10

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "metrics_rules" do
    field :match, :map, default: %{}
    field :patterns, {:array, :string}
    field :export_interval_secs, :integer
    field :expires_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:match, :patterns])
    |> validate_length(:patterns, min: 1)
    |> validate_number(:export_interval_secs, greater_than_or_equal_to: @min_export_interval_secs)
    |> validate_change(:match, fn :match, match ->
      if Enum.all?(match, &valid_condition?/1),
        do: [],
        else: [match: "may only map #{Enum.join(@attributes, ", ")} to strings"]
    end)
  end

  defp valid_condition?({attribute, value}), do: attribute in @attributes and is_binary(value)

  @doc """
  The attributes of `device` of `account` that rules match on.
  """
  @spec attributes(Portal.Account.t(), Portal.Device.t()) :: %{String.t() => String.t()}
  def attributes(%Portal.Account{} = account, %Portal.Device{} = device) do
    %{
      "plan" => account |> Portal.Billing.plan_type() |> Atom.to_string(),
      "account_id" => account.id,
      "actor_id" => device.actor_id,
      "device_id" => device.id,
      "device_type" => device.type && Atom.to_string(device.type)
    }
    |> Map.reject(fn {_attribute, value} -> is_nil(value) end)
  end

  @doc """
  Whether the devices `rule` matches export metrics labelled with the device.
  Only rules targeting a single device or actor do, so labels stay few.
  """
  @spec labels_devices?(t()) :: boolean()
  def labels_devices?(%__MODULE__{match: match}), do: Map.has_key?(match, "device_id") or Map.has_key?(match, "actor_id")

  @spec matches?(t(), %{String.t() => String.t()}) :: boolean()
  def matches?(%__MODULE__{match: match}, attributes) do
    Map.take(attributes, Map.keys(match)) == match
  end

  @doc """
  The unexpired rules matching `attributes`.
  """
  @spec list_matching(%{String.t() => String.t()}) :: [t()]
  defdelegate list_matching(attributes), to: Database

  @doc """
  How many devices `match` matches, with the attributes of `attributes/2`. A
  Client matches `actor_id` if any of its actors has signed in on it.
  """
  @spec count_devices(map()) :: non_neg_integer()
  defdelegate count_devices(match), to: Database

  defmodule Database do
    import Ecto.Query
    alias Portal.{Account, Device, DeviceActor, MetricsRule, Safe}

    def list_matching(attributes) do
      from(r in MetricsRule,
        where: fragment("? <@ ?", r.match, type(^attributes, :map)),
        where: is_nil(r.expires_at) or r.expires_at > fragment("now()")
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    # `plan` follows `Portal.Billing.plan_type/1`.
    def count_devices(match) do
      from(d in Device,
        join: a in Account,
        on: a.id == d.account_id,
        left_join: da in DeviceActor,
        on: da.account_id == d.account_id and da.device_id == d.id,
        where:
          fragment(
            """
            ? <@ jsonb_strip_nulls(jsonb_build_object(
              'plan', CASE
                WHEN ?->'stripe'->>'product_name' LIKE 'Enterprise%' THEN 'enterprise'
                WHEN ?->'stripe'->>'product_name' = 'Business' THEN 'business'
                WHEN ?->'stripe'->>'product_name' = 'Team' THEN 'team'
                WHEN ?->'stripe'->>'product_name' = 'Starter' THEN 'starter'
                ELSE 'unknown'
              END,
              'account_id', ?::text,
              'actor_id', ?::text,
              'device_id', ?::text,
              'device_type', ?
            ))
            """,
            type(^match, :map),
            a.metadata,
            a.metadata,
            a.metadata,
            a.metadata,
            d.account_id,
            da.actor_id,
            d.id,
            d.type
          ),
        distinct: true,
        select: d.id
      )
      |> Safe.unscoped()
      |> Safe.aggregate(:count)
    end
  end
end
