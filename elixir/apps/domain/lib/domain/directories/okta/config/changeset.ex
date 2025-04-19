defmodule Domain.Directories.Okta.Config.Changeset do
  use Domain, :changeset
  alias Domain.Directories.Okta.Config

  @fields ~w[
    client_id
    private_key
    okta_domain
  ]a

  def new do
    %Config{}
    |> cast(%{}, @fields)
  end

  def changeset(%Config{} = config \\ %Config{}, attrs) do
    config
    |> cast(attrs, @fields)
    |> validate_required(@fields)
  end
end
