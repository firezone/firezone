defmodule Domain.Auth.Adapters.Email do
  use Supervisor
  alias Domain.Repo
  alias Domain.Tokens
  alias Domain.Auth.{Identity, Provider, Adapter, Context}

  @behaviour Adapter
  @behaviour Adapter.Local

  @sign_in_token_expiration_seconds 15 * 60
  @sign_in_token_max_attempts 5

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
  def identity_changeset(%Provider{}, %Ecto.Changeset{} = changeset) do
    changeset
    |> Domain.Repo.Changeset.trim_change(:provider_identifier)
    |> Domain.Repo.Changeset.validate_email(:provider_identifier)
    |> Ecto.Changeset.validate_confirmation(:provider_identifier,
      required: true,
      message: "email does not match"
    )
    |> Ecto.Changeset.put_change(:provider_state, %{})
    |> Ecto.Changeset.put_change(:provider_virtual_state, %{})
  end

  @impl true
  def provider_changeset(%Ecto.Changeset{} = changeset) do
    if Domain.Config.fetch_env!(:domain, :outbound_email_adapter_configured?) do
      changeset
    else
      Ecto.Changeset.add_error(changeset, :adapter, "email adapter is not configured")
    end
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

  def request_sign_in_token(%Identity{} = identity, %Context{} = context) do
    nonce = String.downcase(Domain.Crypto.random_token(5, encoder: :user_friendly))
    expires_at = DateTime.utc_now() |> DateTime.add(@sign_in_token_expiration_seconds, :second)
    sequence_number = Map.get(identity.provider_state, "request_sequence_number", 0) + 1

    {:ok, _count} = Tokens.delete_all_tokens_by_type_and_assoc(:email, identity)

    {:ok, token} =
      Tokens.create_token(%{
        type: :email,
        secret_fragment: Domain.Crypto.random_token(27),
        secret_nonce: nonce,
        account_id: identity.account_id,
        actor_id: identity.actor_id,
        identity_id: identity.id,
        remaining_attempts: @sign_in_token_max_attempts,
        expires_at: expires_at,
        created_by_user_agent: context.user_agent,
        created_by_remote_ip: context.remote_ip
      })

    fragment = Tokens.encode_fragment!(token)

    state = %{
      "last_created_token_id" => token.id,
      "token_created_at" => token.inserted_at,
      "request_sequence_number" => sequence_number
    }

    virtual_state = %{nonce: nonce, fragment: fragment}
    Identity.Mutator.update_provider_state(identity, state, virtual_state)
  end

  @impl true
  def verify_secret(%Identity{} = identity, %Context{} = context, encoded_token) do
    with {:ok, token} <- Tokens.use_token(encoded_token, %{context | type: :email}),
         true <- token.identity_id == identity.id do
      {:ok, identity} =
        Identity.Query.not_disabled()
        |> Identity.Query.by_id(identity.id)
        |> Repo.fetch_and_update(Identity.Query,
          with: fn identity ->
            Identity.Changeset.update_identity_provider_state(identity, %{})
          end
        )

      {:ok, _count} = Tokens.delete_all_tokens_by_type_and_assoc(:email, identity)

      {:ok, identity, nil}
    else
      {:error, :invalid_or_expired_token} -> {:error, :invalid_secret}
      false -> {:error, :invalid_secret}
    end
  end
end
