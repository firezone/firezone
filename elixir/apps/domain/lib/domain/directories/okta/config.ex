defmodule Domain.Directories.Okta.Config do
  use Domain, :schema

  @primary_key false
  embedded_schema do
    field :client_id, :string

    # A JWK used to sign JWTs for the Okta API
    field :private_key, :string

    field :okta_domain, :string
  end
end
