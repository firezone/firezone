defmodule Domain.Auth.Adapters.UserPass do
  @moduledoc """
  This is not recommended to use in production,
  it's only for development, testing, and small home labs.
  """
  use Supervisor
  alias Domain.Repo
  alias Domain.Auth.{Identity, Provider, Adapter, Context}
  alias Domain.Auth.Adapters.UserPass.Password

  @behaviour Adapter
  @behaviour Adapter.Local

  def start_link(_init_arg) do
    Supervisor.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = []

    Supervisor.init(children, strategy: :one_for_one)
  end

  @impl true
  def capabilities do
    [
      provisioners: [:manual],
      default_provisioner: :manual,
      parent_adapter: nil
    ]
  end

  @impl true
  def identity_changeset(%Provider{} = _provider, %Ecto.Changeset{} = changeset) do
    changeset
    |> Domain.Validator.trim_change(:provider_identifier)
    |> validate_password()
  end

  defp validate_password(changeset) do
    data = Map.get(changeset.data, :provider_virtual_state) || %{}
    attrs = Ecto.Changeset.get_change(changeset, :provider_virtual_state) || %{}

    Ecto.embedded_load(Password, data, :json)
    |> Password.Changeset.changeset(attrs)
    |> case do
      %{valid?: false} = nested_changeset ->
        {changeset, _original_type} =
          Domain.Changeset.inject_embedded_changeset(
            changeset,
            :provider_virtual_state,
            nested_changeset
          )

        changeset

      %{valid?: true} = nested_changeset ->
        nested_changeset =
          nested_changeset
          |> Domain.Validator.redact_field(:password)
          |> Domain.Validator.redact_field(:password_confirmation)

        password_hash = Ecto.Changeset.fetch_change!(nested_changeset, :password_hash)

        {changeset, _original_type} =
          changeset
          |> Ecto.Changeset.put_change(:provider_state, %{"password_hash" => password_hash})
          |> Domain.Changeset.inject_embedded_changeset(:provider_virtual_state, nested_changeset)

        changeset
    end
  end

  @impl true
  def provider_changeset(%Ecto.Changeset{} = changeset) do
    changeset
  end

  @impl true
  def ensure_provisioned(%Provider{} = provider) do
    {:ok, provider}
  end

  @impl true
  def ensure_deprovisioned(%Provider{} = provider) do
    {:ok, provider}
  end

  @impl true
  def sign_out(%Provider{} = _provider, %Identity{} = identity, redirect_url) do
    {:ok, identity, redirect_url}
  end

  @impl true
  def verify_secret(%Identity{} = identity, %Context{} = _context, password)
      when is_binary(password) do
    Identity.Query.by_id(identity.id)
    |> Repo.fetch_and_update(
      with: fn identity ->
        password_hash = identity.provider_state["password_hash"]

        cond do
          is_nil(password_hash) ->
            :invalid_secret

          not Domain.Crypto.equal?(:argon2, password, password_hash) ->
            :invalid_secret

          true ->
            Ecto.Changeset.change(identity)
        end
      end
    )
    |> case do
      {:ok, identity} ->
        {:ok, identity, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
