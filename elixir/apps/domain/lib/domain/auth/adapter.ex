defmodule Domain.Auth.Adapter do
  alias Domain.Auth.{Provider, Identity}

  @doc """
  Applies provider-specific validations for the Identity changeset before it's created.
  """
  @callback identity_changeset(%Provider{}, %Ecto.Changeset{data: %Identity{}}) ::
              %Ecto.Changeset{data: %Identity{}}

  @doc """
  A callback which is triggered when the provider is first created.

  It should impotently ensure that the provider is provisioned on the third-party end,
  eg. it can use a REST API to configure SCIM webhook and token.
  """
  @callback ensure_provisioned(%Ecto.Changeset{data: %Provider{}}) ::
              %Ecto.Changeset{data: %Provider{}}

  @doc """
  A callback which is triggered when the provider is deleted.

  It should impotently ensure that the provider is deprovisioned on the third-party end,
  eg. it can use a REST API to remove SCIM webhook and token.
  """
  @callback ensure_deprovisioned(%Ecto.Changeset{data: %Provider{}}) ::
              %Ecto.Changeset{data: %Provider{}}

  defmodule Local do
    @doc """
    A callback invoked during sign-in, should verify the secret and return the identity
    if it's valid, or an error otherwise.

    Used by secret-based providers, eg.: UserPass, Email.
    """
    @callback verify_secret(%Identity{}, secret :: term()) ::
                {:ok, %Identity{}, expires_at :: %DateTime{} | nil}
                | {:error, :invalid_secret}
                | {:error, :expired_secret}
                | {:error, :internal_error}
  end

  defmodule IdP do
    @doc """
    Used for adapters that are not secret-based, eg. OpenID Connect.
    """
    @callback verify_identity(%Provider{}, payload :: term()) ::
                {:ok, %Identity{}, expires_at :: %DateTime{} | nil}
                | {:error, :invalid_secret}
                | {:error, :expired_secret}
                | {:error, :internal_error}
  end
end
