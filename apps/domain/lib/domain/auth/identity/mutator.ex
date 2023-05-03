defmodule Domain.Auth.Identity.Mutator do
  alias Domain.Auth.Repo
  alias Domain.Auth.Identity
  require Ecto.Query

  def update_provider_state(identity, state_changeset, virtual_state) do
    Identity.Changeset.provider_state_changeset(identity, state_changeset, virtual_state)
    |> Repo.update()
  end

  def reset_provider_state(queryable) do
    queryable
    |> Ecto.Query.update(set: [provider_state: ^%{}, provider_virtual_state: ^%{}])
    |> Ecto.Query.select([identities: identities], identities)
    |> Repo.update_all([])
    |> case do
      {1, [identity]} -> {:ok, identity}
      {0, []} -> {:error, :not_found}
    end
  end
end
