defmodule Domain.Auth.Adapter do
  alias Domain.Auth.{Provider, Identity, Context}

  @typedoc """
  This type defines which kind of provisioners are enabled for IdP adapter.

  The `:custom` is a special key which means that the IdP adapter implements
  its own provisioning logic (eg. API integration), so it should be rendered
  in the UI on pre-provider basis.

  Setting it to `:custom` will also allow running recurrent jobs for the provider,
  for more details see `Domain.Auth.all_providers_pending_token_refresh_by_adapter!/1`
  and `Domain.Auth.all_providers_pending_sync_by_adapter!/1`.
  """
  @type provisioner :: :manual | :just_in_time | :custom

  @typedoc """
  Setting parent adapter is important because it will allow to reuse auth flows
  on the front-end for multiple IdP adapters.
  """
  @type parent_adapter :: nil | atom()

  @type capability ::
          {:parent_adapter, parent_adapter()}
          | {:provisioners, [provisioner()]}
          | {:default_provisioner, provisioner()}

  @doc """
  This callback returns list of provider capabilities for a better UI rendering.
  """
  @callback capabilities() :: [capability()]

  @doc """
  Applies provider-specific validations for the Identity changeset before it's created.
  """
  @callback identity_changeset(%Provider{}, %Ecto.Changeset{data: %Identity{}}) ::
              %Ecto.Changeset{data: %Identity{}}

  @doc """
  Adds adapter-specific validations to the provider changeset.
  """
  @callback provider_changeset(%Ecto.Changeset{data: %Provider{}}) ::
              %Ecto.Changeset{data: %Provider{}}

  @doc """
  A callback which is triggered when the provider is first created.

  It should impotently ensure that the provider is provisioned on the third-party end,
  eg. it can use a REST API to configure SCIM webhook and token.
  """
  @callback ensure_provisioned(%Provider{}) ::
              {:ok, %Provider{}} | {:error, %Ecto.Changeset{data: %Provider{}}}

  @doc """
  A callback which is triggered when the provider is deleted.

  It should impotently ensure that the provider is deprovisioned on the third-party end,
  eg. it can use a REST API to remove SCIM webhook and token.
  """
  @callback ensure_deprovisioned(%Provider{}) ::
              {:ok, %Provider{}} | {:error, %Ecto.Changeset{data: %Provider{}}}

  @doc """
  A callback which is called to clean up the provider data on sign out and,
  optionally, redirect the user to a different location.
  """
  @callback sign_out(%Provider{}, %Identity{}, redirect_url :: String.t()) ::
              {:ok, %Identity{}, redirect_url :: String.t()}

  defmodule Local do
    @doc """
    A callback invoked during sign-in, should verify the secret and return the identity
    if it's valid, or an error otherwise.

    Used by secret-based providers, eg.: UserPass, Email.
    """
    @callback verify_secret(%Identity{}, %Context{}, secret :: term()) ::
                {:ok, %Identity{}, expires_at :: %DateTime{} | nil}
                | {:error, :invalid_secret}
                | {:error, :expired_secret}
                | {:error, :internal_error}
  end

  defmodule IdP do
    @doc """
    Used for adapters that are not secret-based, eg. OpenID Connect.
    """
    @callback verify_and_update_identity(%Provider{}, payload :: term()) ::
                {:ok, %Identity{}, expires_at :: %DateTime{} | nil}
                | {:error, :invalid_secret}
                | {:error, :expired_secret}
                | {:error, :internal_error}

    @doc """
    This function can be used to refresh the access token for the given identity,
    eg. when we want to extend the lifetime of the browser session token.
    """
    @callback refresh_access_token(%Identity{}) ::
                {:ok, %Identity{}, expires_at :: %DateTime{} | nil}
                | {:error, :expired_token}
                | {:error, :invalid_token}
                | {:error, reason :: term()}
  end
end
