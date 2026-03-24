defmodule Portal.FlowLog do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{
          account_id: Ecto.UUID.t(),
          flow_id: Ecto.UUID.t(),
          device_id: Ecto.UUID.t(),
          role: String.t(),
          flow_start: DateTime.t(),
          flow_end: DateTime.t(),
          payload: map(),
          inserted_at: DateTime.t()
        }

  @roles ~w[initiator responder]

  schema "flow_logs" do
    belongs_to :account, Portal.Account, primary_key: true
    field :flow_id, :binary_id, primary_key: true
    field :device_id, :binary_id, primary_key: true
    field :role, :string
    field :flow_start, :utc_datetime_usec
    field :flow_end, :utc_datetime_usec
    field :payload, :map

    timestamps(updated_at: false)
  end

  @uuid_fields ~w[flow_id account_id device_id]a

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([
      :flow_id,
      :account_id,
      :device_id,
      :role,
      :flow_start,
      :flow_end,
      :payload
    ])
    |> validate_uuids()
    |> validate_inclusion(:role, @roles)
    |> validate_in_past(:flow_start)
    |> validate_in_past(:flow_end)
    |> validate_flow_end_after_start()
    |> check_constraint(:role,
      name: :flow_logs_role_chk,
      message: "must be initiator or responder"
    )
    |> check_constraint(:flow_end,
      name: :flow_end_after_start,
      message: "must be after or equal to flow_start"
    )
    |> check_constraint(:flow_start, name: :flow_start_in_past, message: "must be in the past")
    |> check_constraint(:flow_end, name: :flow_end_in_past, message: "must be in the past")
  end

  defp validate_uuids(changeset) do
    Enum.reduce(@uuid_fields, changeset, fn field, cs ->
      case get_field(cs, field) do
        nil -> cs
        value -> validate_uuid(cs, field, value)
      end
    end)
  end

  defp validate_uuid(changeset, field, value) do
    case Ecto.UUID.cast(value) do
      {:ok, _} -> changeset
      :error -> add_error(changeset, field, "is not a valid UUID")
    end
  end

  defp validate_in_past(changeset, field) do
    case get_field(changeset, field) do
      %DateTime{} = dt ->
        if DateTime.compare(dt, DateTime.utc_now()) == :gt do
          add_error(changeset, field, "must be in the past")
        else
          changeset
        end

      _ ->
        changeset
    end
  end

  defp validate_flow_end_after_start(changeset) do
    flow_start = get_field(changeset, :flow_start)
    flow_end = get_field(changeset, :flow_end)

    if flow_start && flow_end && DateTime.compare(flow_end, flow_start) == :lt do
      add_error(changeset, :flow_end, "must be after or equal to flow_start")
    else
      changeset
    end
  end
end
