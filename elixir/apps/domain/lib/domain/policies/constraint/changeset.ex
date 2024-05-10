defmodule Domain.Policies.Constraint.Changeset do
  use Domain, :changeset
  alias Domain.Policies.Constraint

  def changeset(%Constraint{} = constraint, attrs) do
    constraint
    |> cast(attrs, [:property, :operator, :values])
    |> validate_required([:property, :operator])
    |> validate_operator()
    |> validate_values()
  end

  defp validate_operator(changeset) do
    case fetch_field(changeset, :property) do
      {_data_or_changes, :remote_ip_location_region} ->
        changeset
        |> validate_required(:operator)
        |> validate_inclusion(:operator, [:is_in, :is_not_in])
        |> validate_subset(:values, Domain.Geo.all_country_codes!())

      {_data_or_changes, :remote_ip} ->
        changeset
        |> validate_required(:operator)
        |> validate_inclusion(:operator, [:is_in_cidr, :is_not_in_cidr])
        |> validate_list(:values, Domain.Types.CIDR)

      {_data_or_changes, :provider_id} ->
        changeset
        |> validate_required(:operator)
        |> validate_inclusion(:operator, [:is_in, :is_not_in])
        |> validate_list(:values, Ecto.UUID)

      {_data_or_changes, :current_utc_datetime} ->
        changeset
        |> validate_required(:operator)
        |> validate_inclusion(:operator, [:is_in_day_of_week_time_ranges])
        |> validate_list(:values, :string, fn changeset, field ->
          validate_change(changeset, field, fn field, value ->
            case Constraint.Evaluator.parse_day_of_week_time_ranges(value) do
              {:ok, _dow_time_ranges} ->
                []

              {:error, reason} ->
                [{field, reason}]
            end
          end)
        end)

      :error ->
        add_error(changeset, :property, "is not supported")
    end
  end

  defp validate_values(changeset) do
    case fetch_field(changeset, :operator) do
      {_data_or_changes, :contains} ->
        changeset
        |> validate_required(:values)

      {_data_or_changes, :does_not_contain} ->
        changeset
        |> validate_required(:values)

      {_data_or_changes, :is_in} ->
        changeset
        |> validate_required(:values)

      # |> validate_cidr(:values)

      {_data_or_changes, :is_not_in} ->
        changeset
        |> validate_required(:values)

      {_data_or_changes, :is_in_day_of_week_time_ranges} ->
        changeset
        |> validate_required(:values)

      {_data_or_changes, _other} ->
        changeset
    end
  end
end
