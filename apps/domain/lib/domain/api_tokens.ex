defmodule Domain.ApiTokens do
  alias Domain.{Repo, Validator, Auth}
  alias Domain.Actors
  alias Domain.ApiTokens.Authorizer
  alias Domain.ApiTokens.ApiToken

  def count_by_actor_id(actor_id) do
    ApiToken.Query.by_actor_id(actor_id)
    |> Repo.aggregate(:count)
  end

  def list_api_tokens(%Auth.Subject{} = subject) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_api_tokens_permission(),
         Authorizer.manage_own_api_tokens_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions) do
      ApiToken.Query.all()
      |> Authorizer.for_subject(subject)
      |> Repo.list()
    end
  end

  def list_api_tokens_by_actor_id(actor_id, %Auth.Subject{} = subject) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_api_tokens_permission(),
         Authorizer.manage_own_api_tokens_permission()
       ]}

    with true <- Validator.valid_uuid?(actor_id),
         :ok <- Auth.ensure_has_permissions(subject, required_permissions) do
      ApiToken.Query.by_actor_id(actor_id)
      |> Authorizer.for_subject(subject)
      |> Repo.list()
    else
      false -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  def fetch_api_token_by_id(id, %Auth.Subject{} = subject) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_api_tokens_permission(),
         Authorizer.manage_own_api_tokens_permission()
       ]}

    with true <- Validator.valid_uuid?(id),
         :ok <- Auth.ensure_has_permissions(subject, required_permissions) do
      ApiToken.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch()
    else
      false -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def fetch_unexpired_api_token_by_id(id, %Auth.Subject{} = subject) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_api_tokens_permission(),
         Authorizer.manage_own_api_tokens_permission()
       ]}

    with true <- Validator.valid_uuid?(id),
         :ok <- Auth.ensure_has_permissions(subject, required_permissions) do
      ApiToken.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> ApiToken.Query.not_expired()
      |> Repo.fetch()
    else
      false -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def fetch_unexpired_api_token_by_id(id) do
    if Validator.valid_uuid?(id) do
      ApiToken.Query.by_id(id)
      |> ApiToken.Query.not_expired()
      |> Repo.fetch()
    else
      {:error, :not_found}
    end
  end

  def new_api_token(attrs \\ %{}) do
    ApiToken.Changeset.changeset(attrs)
  end

  def create_api_token(attrs, %Auth.Subject{} = subject) do
    with :ok <-
           Auth.ensure_has_permissions(
             subject,
             Authorizer.manage_own_api_tokens_permission()
           ) do
      {:actor, actor} = subject.actor
      create_api_token(actor, attrs)
    end
  end

  def create_api_token(%Actors.Actor{} = actor, attrs) do
    count_by_actor_id = count_by_actor_id(actor.id)
    changeset = ApiToken.Changeset.create_changeset(actor, attrs, max: count_by_actor_id)

    with {:ok, api_token} <- Repo.insert(changeset) do
      Domain.Telemetry.create_api_token()
      {:ok, api_token}
    end
  end

  def api_token_expired?(%ApiToken{} = api_token) do
    DateTime.diff(api_token.expires_at, DateTime.utc_now()) < 0
  end

  def delete_api_token_by_id(api_token_id, %Auth.Subject{} = subject) do
    with {:ok, api_token} <- fetch_api_token_by_id(api_token_id, subject),
         :ok <- Authorizer.ensure_can_manage(subject, api_token) do
      {:ok, Repo.delete!(api_token)}
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, {:unauthorized, context}} -> {:error, {:unauthorized, context}}
      {:error, :unauthorized} -> {:error, :not_found}
    end
  end
end
