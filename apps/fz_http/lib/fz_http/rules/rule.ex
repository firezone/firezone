defmodule FzHttp.Rules.Rule do
  @moduledoc """
  Not really sure what to write here. I'll update this later.
  """

  use Ecto.Schema
  alias FzHttp.Rules
  import Ecto.Changeset

  @rule_dupe_msg "A rule with that specification already exists."
  @default_action :drop

  schema "rules" do
    field :uuid, Ecto.UUID, autogenerate: true
    field :destination, EctoNetwork.INET, read_after_writes: true
    field :action, Ecto.Enum, values: [:drop, :accept], default: @default_action
    belongs_to :user, FzHttp.Users.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [
      :user_id,
      :action,
      :destination
    ])
    |> validate_required([:action, :destination])
    |> unique_constraint([:user_id, :destination, :action], message: @rule_dupe_msg)
    |> validate_non_overlap()
  end

  defp validate_non_overlap(%{changes: changes, valid?: true} = changeset) do
    case Rules.overlap(Map.put_new(changes, :action, @default_action)) do
      nil ->
        changeset

      rule ->
        add_error(
          changeset,
          :destination,
          "Destination overlaps with an existing rule: Destination: #{FzHttp.Devices.decode(rule.destination)}" <>
            if(Map.has_key?(changes, :user_id) and FzHttp.Users.exists?(changes.user_id),
              do: ", User Scope: #{FzHttp.Users.get_user(changes.user_id).email}",
              else: ""
            )
        )
    end
  end

  defp validate_non_overlap(changeset) do
    changeset
  end
end
