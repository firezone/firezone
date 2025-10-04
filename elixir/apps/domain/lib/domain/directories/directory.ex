defmodule Domain.Directories.Directory do
  use Domain, :schema

  # This table is used as a foreign key target only
  @primary_key false
  schema "directories" do
    belongs_to :account, Domain.Accounts.Account, primary_key: true
    field :id, :binary_id, primary_key: true, read_after_writes: true

    field :type, Ecto.Enum, values: [:okta, :google, :entra, :firezone]
    has_many :okta_directories, Domain.Okta.Directory, where: [type: :okta], references: :id
    has_many :google_directories, Domain.Google.Directory, where: [type: :google], references: :id
    has_many :entra_directories, Domain.Entra.Directory, where: [type: :entra], references: :id

    has_one :firezone_directory, Domain.Firezone.Directory,
      where: [type: :firezone],
      references: :id
  end
end
