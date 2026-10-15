defmodule Portal.AccountActivityRollup do
  @moduledoc """
  The single watermark row of `Portal.Workers.RollupAccountActivity`. Activity
  up to `processed_until` is already recorded in `accounts.last_active_at`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :boolean, autogenerate: false}

  schema "account_activity_rollups" do
    field :processed_until, :utc_datetime_usec
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:processed_until])
    |> check_constraint(:id, name: :singleton)
  end
end
