defmodule Domain.Firezone.Directory do
  use Domain, :schema

  @primary_key false
  schema "firezone_directories" do
    belongs_to :account, Domain.Accounts.Account
    belongs_to :directory, Domain.Directories.Directory, primary_key: true

    field :jit_provisioning, :boolean

    subject_trail(~w[actor identity system]a)
    timestamps()
  end
end
