defmodule Portal.Policies.Condition do
  use Ecto.Schema
  import Ecto.Changeset
  import Portal.Changeset

  @primary_key false

  @type t :: %__MODULE__{
          property:
            :remote_ip_location_region
            | :remote_ip
            | :auth_provider_id
            | :current_utc_datetime
            | :client_verified,
          operator:
            :contains
            | :does_not_contain
            | :is_in
            | :is_not_in
            | :is_in_day_of_week_time_ranges
            | :is_in_cidr
            | :is_not_in_cidr
            | :is,
          values: [String.t()]
        }

  embedded_schema do
    field :property, Ecto.Enum, values: ~w[
        remote_ip_location_region
        remote_ip
        auth_provider_id
        current_utc_datetime
        client_verified
      ]a

    field :operator, Ecto.Enum, values: ~w[
        contains does_not_contain
        is_in is_not_in
        is_in_day_of_week_time_ranges
        is_in_cidr is_not_in_cidr
        is
      ]a

    field :values, {:array, :string}
  end

  # Changeset functions

  def changeset(%__MODULE__{} = condition, attrs, _position) do
    condition
    |> cast(attrs, [:property, :operator, :values])
    |> put_default_value(:property, :remote_ip_location_region)
    |> put_default_value(:operator, :is_in)
    |> validate_required([:property, :operator])
    |> validate_operator()
    |> trim_change([:values])
  end

  def valid_operators_for_property(:remote_ip_location_region), do: [:is_in, :is_not_in]
  def valid_operators_for_property(:remote_ip), do: [:is_in_cidr, :is_not_in_cidr]
  def valid_operators_for_property(:auth_provider_id), do: [:is_in, :is_not_in]
  def valid_operators_for_property(:current_utc_datetime), do: [:is_in_day_of_week_time_ranges]
  def valid_operators_for_property(:client_verified), do: [:is]

  defp validate_operator(changeset) do
    case fetch_field(changeset, :property) do
      {_data_or_changes, :remote_ip_location_region} ->
        changeset
        |> validate_required(:operator)
        |> validate_inclusion(:operator, valid_operators_for_property(:remote_ip_location_region))
        |> validate_subset(:values, Portal.Geo.all_country_codes!())

      {_data_or_changes, :remote_ip} ->
        changeset
        |> validate_required(:operator)
        |> validate_inclusion(:operator, valid_operators_for_property(:remote_ip))
        |> validate_list(:values, Portal.Types.INET)

      {_data_or_changes, :auth_provider_id} ->
        changeset
        |> validate_required(:operator)
        |> validate_inclusion(:operator, valid_operators_for_property(:auth_provider_id))
        |> validate_list(:values, Ecto.UUID)

      {_data_or_changes, :current_utc_datetime} ->
        changeset
        |> validate_required(:operator)
        |> validate_inclusion(:operator, valid_operators_for_property(:current_utc_datetime))
        |> validate_list(:values, :string, fn changeset, field ->
          validate_day_of_week_time_ranges(changeset, field)
        end)

      {_data_or_changes, :client_verified} ->
        changeset
        |> validate_required(:operator)
        |> validate_inclusion(:operator, valid_operators_for_property(:client_verified))
        |> validate_length(:values, min: 1, max: 1)
        |> validate_list(:values, :boolean)

      {_data_or_changes, nil} ->
        changeset

      :error ->
        add_error(changeset, :property, "is not supported")
    end
  end

  def validate_day_of_week_time_ranges(changeset, field) do
    validate_change(changeset, field, fn field, value ->
      case Portal.Policies.Evaluator.parse_day_of_week_time_ranges(value) do
        {:ok, _dow_time_ranges} ->
          []

        {:error, reason} ->
          [{field, reason}]
      end
    end)
  end
end
