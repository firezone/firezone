defmodule Domain.Repo.Migration do
  import Ecto.Migration

  @moduledoc """
    Provide helpers to add common fields used in all tables.
  """

  def subject_trail do
    add(:created_by, :string, null: false)
    add(:created_by_subject, :map)
  end

  def account(opts \\ []) do
    opts = Keyword.put_new(opts, :null, false)
    add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all), opts)
  end
end
