defmodule Domain.Auth.Identity.Mutator do
  alias Domain.Repo
  alias Domain.Auth.Identity
  require Ecto.Query

  def update_provider_state(identity, state_changeset, virtual_state \\ %{}) do
    Identity.Changeset.update_identity_provider_state(identity, state_changeset, virtual_state)
    |> Repo.update()
  end
end
