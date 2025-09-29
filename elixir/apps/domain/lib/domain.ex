defmodule Domain do
  @moduledoc """
  This module provides a common interface for all the domain modules,
  making sure our code structure is consistent and predictable.
  """

  defmacro subject_trail(values \\ []) do
    quote do
      field(:created_by, Ecto.Enum, values: unquote(values))
      field(:created_by_subject, :map)
    end
  end

  def schema do
    quote do
      use Ecto.Schema
      import Domain, only: [subject_trail: 1]

      @primary_key {:id, :binary_id, autogenerate: true}
      @foreign_key_type :binary_id

      @timestamps_opts [type: :utc_datetime_usec]

      @type id :: binary()
    end
  end

  def changeset do
    quote do
      import Ecto.Changeset
      import Domain.Repo.Changeset
      import Domain.Repo, only: [valid_uuid?: 1]
    end
  end

  def query do
    quote do
      import Ecto.Query
      import Domain.Repo.Query

      @behaviour Domain.Repo.Query
    end
  end

  def migration do
    quote do
      use Ecto.Migration
      import Domain.Repo.Migration
    end
  end

  @doc """
  When used, dispatch to the appropriate schema/context/changeset/query/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
