defmodule Domain.Auth.Adapter do
  alias Domain.Auth.Provider

  # TOOD:
  # @callback child_spec(map) :: Supervisor.child_spec()

  @doc """
  A callback which is triggered when the provider is first created.

  It should impotently ensure that the provider is provisioned on the third-party end,
  eg. it can use a REST API to configure SCIM webhook and token.
  """
  @callback ensure_provisioned(%Provider{}) ::
              {:ok, %Provider{}} | {:error, Ecto.Changeset.t()}

  @doc """
  A callback which is triggered when the provider is deleted.

  It should impotently ensure that the provider is deprovisioned on the third-party end,
  eg. it can use a REST API to remove SCIM webhook and token.
  """
  @callback ensure_deprovisioned(%Provider{}) :: {:ok, %Provider{}}

  # TODO
  # @callback sync(%Provider{}) :: {:ok, users :: [map], groups :: [map]}

  @callback sign_in(attrs :: map) :: {:ok, user :: map} | {:error, reason :: any}
end
