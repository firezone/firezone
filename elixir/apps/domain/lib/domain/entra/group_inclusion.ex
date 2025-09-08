defmodule Domain.Entra.GroupInclusion do
  use Domain, :schema

  @primary_key false
  schema "entra_group_inclusions" do
    belongs_to :account, Domain.Accounts.Account, primary_key: true
    belongs_to :directory, Domain.Entra.Directory, primary_key: true

    # Group external ID in the IdP
    field :external_id, :string, primary_key: true

    timestamps(updated_at: false)
  end
end
