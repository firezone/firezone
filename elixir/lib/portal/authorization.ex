defmodule Portal.Authorization do
  @moduledoc """
  Centralized authorization and database access control.

  This module provides the `with_subject/2` wrapper function that sets the subject
  context for the current process. When set, Portal.Repo automatically:
  1. Applies account_id filtering to queries (via prepare_query callback)
  2. Checks authorization for the requested operation
  3. Emits audit logging for mutations

  All Repo operations that require authorization should be wrapped in `with_subject/2`:

      Authorization.with_subject(subject, fn ->
        Repo.all(query)
        Repo.insert(changeset)
      end)
  """

  alias Portal.Authentication.Subject
  require Logger

  @subject_key :firezone_current_subject

  @doc """
  Wraps database operations with subject context.

  Sets the subject in the process dictionary so that Portal.Repo can
  automatically apply account filtering and authorization checks via
  the `prepare_query/3` callback.

  Supports nesting - restores the previous subject on exit.

  ## Examples

      Authorization.with_subject(subject, fn ->
        Repo.all(query)
        Repo.insert(changeset)
      end)
  """
  @spec with_subject(Subject.t(), (-> result)) :: result when result: var
  def with_subject(%Subject{} = subject, fun) when is_function(fun, 0) do
    previous = Process.get(@subject_key)
    Process.put(@subject_key, subject)

    try do
      fun.()
    after
      if previous do
        Process.put(@subject_key, previous)
      else
        Process.delete(@subject_key)
      end
    end
  end

  @doc """
  Returns the current subject from the process dictionary, or nil.
  """
  @spec current_subject() :: Subject.t() | nil
  def current_subject do
    Process.get(@subject_key)
  end

  @doc """
  Checks if a subject is authorized to perform an action on a schema.

  Returns :ok if authorized, {:error, :unauthorized} otherwise.
  Logs unauthorized access attempts for security auditing.
  """
  @spec authorize(atom(), module(), Subject.t()) :: :ok | {:error, :unauthorized}
  def authorize(action, schema, %Subject{} = subject) do
    authorize_by_actor_type(action, schema, subject.actor.type)
  end

  @doc """
  Emits subject information to the replication stream for audit logging.
  """
  def emit_subject_message(%Subject{} = subject) do
    ip_string =
      try do
        to_string(:inet.ntoa(subject.context.remote_ip))
      rescue
        _ -> "unknown"
      end

    subject_info = %{
      "ip" => ip_string,
      "ip_region" => subject.context.remote_ip_location_region,
      "ip_city" => subject.context.remote_ip_location_city,
      "ip_lat" => subject.context.remote_ip_location_lat,
      "ip_lon" => subject.context.remote_ip_location_lon,
      "user_agent" => subject.context.user_agent,
      "actor_name" => subject.actor.name,
      "actor_type" => to_string(subject.actor.type),
      "actor_email" => subject.actor.email,
      "actor_id" => subject.actor.id,
      "auth_provider_id" => subject.credential.auth_provider_id
    }

    case Jason.encode(subject_info) do
      {:ok, message} ->
        case Portal.Repo.query("SELECT pg_logical_emit_message(true, 'subject', $1)", [message]) do
          {:ok, _} ->
            :ok

          {:error, error} ->
            Logger.error("Failed to emit subject message for audit log",
              error: inspect(error),
              actor_id: subject.actor.id
            )

            :ok
        end

      {:error, error} ->
        Logger.error("Failed to encode subject info for audit log",
          error: inspect(error),
          actor_id: subject.actor.id
        )

        :ok
    end
  end

  # Account permissions
  defp authorize_by_actor_type(_action, Portal.Account, :account_admin_user), do: :ok
  defp authorize_by_actor_type(:read, Portal.Account, :api_client), do: :ok
  defp authorize_by_actor_type(:read, Portal.Account, :account_user), do: :ok
  defp authorize_by_actor_type(:read, Portal.Account, :service_account), do: :ok

  # Admin-only permissions (both account_admin_user and api_client)
  defp authorize_by_actor_type(_action, Portal.Actor, :account_admin_user), do: :ok
  defp authorize_by_actor_type(_action, Portal.Actor, :api_client), do: :ok
  defp authorize_by_actor_type(_action, Portal.Group, :account_admin_user), do: :ok
  defp authorize_by_actor_type(_action, Portal.Group, :api_client), do: :ok
  defp authorize_by_actor_type(:read, Portal.Group, :account_user), do: :ok
  defp authorize_by_actor_type(_action, Portal.ExternalIdentity, :account_admin_user), do: :ok
  defp authorize_by_actor_type(_action, Portal.ExternalIdentity, :api_client), do: :ok
  defp authorize_by_actor_type(_action, Portal.ClientToken, :account_admin_user), do: :ok
  defp authorize_by_actor_type(_action, Portal.APIToken, :account_admin_user), do: :ok
  defp authorize_by_actor_type(_action, Portal.Directory, :account_admin_user), do: :ok
  defp authorize_by_actor_type(:read, Portal.Directory, :api_client), do: :ok
  defp authorize_by_actor_type(_action, Portal.AuthProvider, :account_admin_user), do: :ok
  defp authorize_by_actor_type(:read, Portal.AuthProvider, :api_client), do: :ok
  defp authorize_by_actor_type(_action, Portal.Entra.AuthProvider, :account_admin_user), do: :ok
  defp authorize_by_actor_type(:read, Portal.Entra.AuthProvider, :api_client), do: :ok
  defp authorize_by_actor_type(_action, Portal.Google.AuthProvider, :account_admin_user), do: :ok
  defp authorize_by_actor_type(:read, Portal.Google.AuthProvider, :api_client), do: :ok
  defp authorize_by_actor_type(_action, Portal.Okta.AuthProvider, :account_admin_user), do: :ok
  defp authorize_by_actor_type(:read, Portal.Okta.AuthProvider, :api_client), do: :ok
  defp authorize_by_actor_type(_action, Portal.OIDC.AuthProvider, :account_admin_user), do: :ok
  defp authorize_by_actor_type(:read, Portal.OIDC.AuthProvider, :api_client), do: :ok

  defp authorize_by_actor_type(_action, Portal.EmailOTP.AuthProvider, :account_admin_user),
    do: :ok

  defp authorize_by_actor_type(:read, Portal.EmailOTP.AuthProvider, :api_client), do: :ok

  defp authorize_by_actor_type(_action, Portal.Userpass.AuthProvider, :account_admin_user),
    do: :ok

  defp authorize_by_actor_type(:read, Portal.Userpass.AuthProvider, :api_client), do: :ok
  defp authorize_by_actor_type(_action, Portal.Entra.Directory, :account_admin_user), do: :ok
  defp authorize_by_actor_type(:read, Portal.Entra.Directory, :api_client), do: :ok
  defp authorize_by_actor_type(_action, Portal.Google.Directory, :account_admin_user), do: :ok
  defp authorize_by_actor_type(:read, Portal.Google.Directory, :api_client), do: :ok
  defp authorize_by_actor_type(_action, Portal.Okta.Directory, :account_admin_user), do: :ok
  defp authorize_by_actor_type(:read, Portal.Okta.Directory, :api_client), do: :ok

  defp authorize_by_actor_type(_action, Portal.PortalSession, :account_admin_user), do: :ok

  # Oban.Job permissions - admin only
  defp authorize_by_actor_type(:read, Oban.Job, :account_admin_user), do: :ok

  # Client permissions
  defp authorize_by_actor_type(_action, Portal.Client, :account_admin_user), do: :ok
  defp authorize_by_actor_type(_action, Portal.Client, :api_client), do: :ok
  defp authorize_by_actor_type(:read, Portal.Client, :account_user), do: :ok
  defp authorize_by_actor_type(:update, Portal.Client, :account_user), do: :ok
  defp authorize_by_actor_type(:read, Portal.Client, :service_account), do: :ok
  defp authorize_by_actor_type(:update, Portal.Client, :service_account), do: :ok

  # PolicyAuthorization permissions - all actor types can read and create policy_authorizations
  defp authorize_by_actor_type(:read, Portal.PolicyAuthorization, _), do: :ok
  defp authorize_by_actor_type(:insert, Portal.PolicyAuthorization, _), do: :ok
  # Only admin can delete policy_authorizations
  defp authorize_by_actor_type(_action, Portal.PolicyAuthorization, :account_admin_user), do: :ok

  # Gateway permissions
  defp authorize_by_actor_type(_action, Portal.Gateway, :account_admin_user), do: :ok
  defp authorize_by_actor_type(_action, Portal.Gateway, :api_client), do: :ok
  defp authorize_by_actor_type(:read, Portal.Gateway, _), do: :ok

  # Site permissions
  defp authorize_by_actor_type(_action, Portal.Site, :account_admin_user), do: :ok
  defp authorize_by_actor_type(_action, Portal.Site, :api_client), do: :ok
  defp authorize_by_actor_type(:read, Portal.Site, _), do: :ok

  # GatewayToken permissions
  defp authorize_by_actor_type(_action, Portal.GatewayToken, :account_admin_user), do: :ok
  defp authorize_by_actor_type(_action, Portal.GatewayToken, :api_client), do: :ok

  # Resource permissions
  defp authorize_by_actor_type(_action, Portal.Resource, :account_admin_user), do: :ok
  defp authorize_by_actor_type(_action, Portal.Resource, :api_client), do: :ok
  defp authorize_by_actor_type(:read, Portal.Resource, _), do: :ok

  # Policy permissions
  defp authorize_by_actor_type(_action, Portal.Policy, :account_admin_user), do: :ok
  defp authorize_by_actor_type(_action, Portal.Policy, :api_client), do: :ok
  defp authorize_by_actor_type(:read, Portal.Policy, _), do: :ok

  # Membership permissions
  defp authorize_by_actor_type(_action, Portal.Membership, :account_admin_user), do: :ok
  defp authorize_by_actor_type(_action, Portal.Membership, :api_client), do: :ok
  defp authorize_by_actor_type(:read, Portal.Membership, _), do: :ok

  # Catch-all for unauthorized access
  defp authorize_by_actor_type(action, schema, actor_type) do
    Logger.warning("Unauthorized database access attempt",
      action: action,
      schema: schema,
      actor_type: actor_type
    )

    {:error, :unauthorized}
  end
end
