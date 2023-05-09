defmodule Domain.Auth.Adapter do
  alias Domain.Auth.{Provider, Identity}

  @doc """
  Allows provider module to start stateful components.

  See `c:Supervisor.init/1` for more information.
  """
  @callback init(init_arg :: term()) ::
              {:ok, {Supervisor.sup_flags(), [Supervisor.child_spec()]}}
              | :ignore

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

  @doc """
  A callback invoked during sign-in, should verify the secret and return the identity
  if it's valid, or an error otherwise.
  """
  @callback verify_secret(%Provider{}, %Identity{}, secret :: term()) ::
              {:ok, %Identity{}}
              | {:error, :invalid_secret}
              | {:error, :expired_secret}
end
