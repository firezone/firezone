defmodule Domain.Safe do
  @moduledoc """
    Centralized module to handle all DB operations requiring authorization checks.
  """

  import Ecto.Query, warn: false
  import Ecto.Changeset

  alias Ecto.Changeset

  alias Domain.{
    Auth.Subject,
    Repo,
    Entra,
    Google,
    Okta,
    OIDC,
    EmailOTP,
    Userpass
  }

  def one(queryable, %Subject{account: %{id: account_id}} = subject) do
    schema = get_schema_module(queryable)

    with :ok <- permit(:read, schema, subject) do
      queryable
      |> where(account_id: ^account_id)
      |> Repo.one()
    end
  end

  def one!(queryable, %Subject{account: %{id: account_id}} = subject) do
    schema = get_schema_module(queryable)

    with :ok <- permit(:read, schema, subject) do
      queryable
      |> where(account_id: ^account_id)
      |> Repo.one!()
    end
  end

  def all(queryable, %Subject{account: %{id: account_id}} = subject) do
    schema = get_schema_module(queryable)

    with :ok <- permit(:read, schema, subject) do
      queryable
      |> where(account_id: ^account_id)
      |> Repo.all()
    end
  end

  def insert(%Changeset{} = changeset, %Subject{} = subject) do
    changeset = %{changeset | action: :insert}
    schema = get_schema_module(changeset.data)

    with :ok <- permit(:insert, schema, subject) do
      changeset
      |> put_change(:account_id, subject.account.id)
      |> put_subject_trail(subject)
      |> Repo.insert()
    end
  end

  def update(%Changeset{} = changeset, %Subject{} = subject) do
    changeset = %{changeset | action: :update}
    schema = get_schema_module(changeset.data)

    with :ok <- permit(:update, schema, subject) do
      Repo.update(changeset)
    end
  end

  def delete(queryable, %Subject{account: %{id: account_id}} = subject) do
    schema = get_schema_module(queryable)

    with :ok <- permit(:delete, schema, subject) do
      queryable
      |> where(account_id: ^account_id)
      |> Repo.delete()
    end
  end

  # TODO: AUDIT LOGS
  # update and delete subject trails

  defp put_subject_trail(changeset, %Subject{} = subject) do
    changeset
    |> put_change(:created_by, :actor)
    |> put_change(:created_by_subject, %{
      "ip" => subject.context.remote_ip,
      "ip_region" => subject.context.remote_ip_location_region,
      "ip_city" => subject.context.remote_ip_location_city,
      "ip_lat" => subject.context.remote_ip_location_lat,
      "ip_lon" => subject.context.remote_ip_location_lon,
      "user_agent" => subject.context.user_agent,
      "email" => subject.actor.email,
      "id" => subject.actor.id
    })
  end

  defp get_schema_module(%Ecto.Query{from: %{source: {_table, schema}}}), do: schema
  defp get_schema_module(struct) when is_struct(struct), do: struct.__struct__
  defp get_schema_module(module) when is_atom(module), do: module
  defp get_schema_module(_), do: nil

  defp permit(action, schema, %Subject{} = subject) do
    permit(action, schema, subject.actor.type)
  end

  defp permit(_action, Entra.AuthProvider, :account_admin_user), do: :ok
  defp permit(_action, Google.AuthProvider, :account_admin_user), do: :ok
  defp permit(_action, Okta.AuthProvider, :account_admin_user), do: :ok
  defp permit(_action, OIDC.AuthProvider, :account_admin_user), do: :ok
  defp permit(_action, EmailOTP.AuthProvider, :account_admin_user), do: :ok
  defp permit(_action, Userpass.AuthProvider, :account_admin_user), do: :ok
  defp permit(_action, Entra.Directory, :account_admin_user), do: :ok
  defp permit(_action, Google.Directory, :account_admin_user), do: :ok
  defp permit(_action, Okta.Directory, :account_admin_user), do: :ok

  defp permit(_action, _struct, _type), do: {:error, :unauthorized}
end
