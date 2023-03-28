defmodule FzHttp.Rules.Rule.Changeset do
  use FzHttp, :changeset
  alias FzHttp.Rules.Rule

  @exclusion_msg "destination overlaps with an existing rule"
  @port_range_msg "port is not within valid range"
  @port_type_msg "port_type must be specified with port_range"

  @fields ~w[action destination port_type port_range user_id]a
  @port_based_fields ~w[port_type port_range]a
  @required_fields ~w[action destination]a

  def create_changeset(attrs) do
    update_changeset(%Rule{}, attrs)
  end

  def update_changeset(rule, attrs) do
    fields =
      if FzHttp.Rules.port_rules_supported?() do
        @fields
      else
        @fields -- @port_based_fields
      end

    rule
    |> cast(attrs, fields)
    |> validate_required(@required_fields)
    |> validate_required_group(~w[port_range port_type]a)
    |> check_constraint(:port_range,
      message: @port_range_msg,
      name: :port_range_is_within_valid_values
    )
    |> check_constraint(:port_type,
      message: @port_type_msg,
      name: :port_range_needs_type
    )
    |> exclusion_constraint(:destination,
      message: @exclusion_msg,
      name: :destination_overlap_excl_usr_rule
    )
    |> exclusion_constraint(:destination,
      message: @exclusion_msg,
      name: :destination_overlap_excl
    )
    |> exclusion_constraint(:destination,
      message: @exclusion_msg,
      name: :destination_overlap_excl_port
    )
    |> exclusion_constraint(:destination,
      message: @exclusion_msg,
      name: :destination_overlap_excl_usr_rule_port
    )
    |> assoc_constraint(:user)
  end
end
