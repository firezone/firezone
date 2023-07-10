defmodule Domain.Auth.Adapters.GoogleWorkspace do
  use Supervisor
  alias Domain.Auth.{Provider, Adapter}
  alias Domain.Auth.Adapters.OpenIDConnect
  alias Domain.Auth.Adapters.GoogleWorkspace
  require Logger

  @behaviour Adapter
  @behaviour Adapter.IdP

  def start_link(_init_arg) do
    Supervisor.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      GoogleWorkspace.APIClient
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def capabilities do
    [
      provisioners: [:custom, :jit, :none]
    ]
  end

  @impl true
  def identity_changeset(%Provider{} = provider, %Ecto.Changeset{} = changeset) do
    OpenIDConnect.identity_changeset(provider, changeset)
  end

  @impl true
  def ensure_provisioned(%Ecto.Changeset{} = changeset) do
    Domain.Changeset.cast_polymorphic_embed(changeset, :adapter_config,
      required: true,
      with: fn current_attrs, attrs ->
        Ecto.embedded_load(GoogleWorkspace.Settings, current_attrs, :json)
        |> OpenIDConnect.Settings.Changeset.changeset(attrs)
      end
    )
  end

  @impl true
  def ensure_deprovisioned(%Ecto.Changeset{} = changeset) do
    OpenIDConnect.ensure_deprovisioned(changeset)
  end

  @impl true
  def verify_identity(%Provider{} = provider, payload) do
    OpenIDConnect.verify_identity(provider, payload)
  end
end
