defmodule Domain.Policies.Options.Changeset do
  use Domain, :changeset
  alias Domain.Policies.Options

  def changeset(%Options{} = options, attrs) do
    options
    |> cast(attrs, [:allow_clients_to_bypass])
  end
end
