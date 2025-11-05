defmodule Domain.Safe do
  @moduledoc """
    Centralized module to handle all DB operations requiring authorization checks.
  """

  import Ecto.Query, warn: false
  import Ecto.Changeset

  alias Domain.{Auth.Subject, Repo}

  defmodule Scoped do
    @moduledoc """
    Scoped context that carries authorization information.
    """
    @type t :: %__MODULE__{subject: Subject.t()}

    defstruct [:subject]
  end

  @doc """
  Returns a scoped context for operations with authorization and account filtering.
  """
  @spec scoped(Subject.t()) :: Scoped.t()
  def scoped(%Subject{} = subject) do
    %Scoped{subject: subject}
  end

  @doc """
  Returns the Repo module for unscoped operations without authorization or filtering.
  """
  def unscoped do
    Repo
  end

  # Query operations
  @spec one(Scoped.t(), Ecto.Queryable.t()) :: Ecto.Schema.t() | nil | {:error, :unauthorized}
  def one(%Scoped{subject: %Subject{account: %{id: account_id}} = subject}, queryable) do
    schema = get_schema_module(queryable)

    with :ok <- permit(:read, schema, subject) do
      queryable
      |> where(account_id: ^account_id)
      |> Repo.one()
    end
  end

  def one(repo, queryable) when repo == Repo, do: Repo.one(queryable)

  @spec one!(Scoped.t(), Ecto.Queryable.t()) :: Ecto.Schema.t() | no_return()
  def one!(%Scoped{subject: %Subject{account: %{id: account_id}} = subject}, queryable) do
    schema = get_schema_module(queryable)

    with :ok <- permit(:read, schema, subject) do
      queryable
      |> where(account_id: ^account_id)
      |> Repo.one!()
    end
  end

  def one!(repo, queryable) when repo == Repo, do: Repo.one!(queryable)

  @spec all(Scoped.t(), Ecto.Queryable.t()) :: [Ecto.Schema.t()] | {:error, :unauthorized}
  def all(%Scoped{subject: %Subject{account: %{id: account_id}} = subject}, queryable) do
    schema = get_schema_module(queryable)

    with :ok <- permit(:read, schema, subject) do
      queryable
      |> where(account_id: ^account_id)
      |> Repo.all()
    end
  end

  def all(repo, queryable) when repo == Repo, do: Repo.all(queryable)

  @spec exists?(Scoped.t(), Ecto.Queryable.t()) :: boolean() | {:error, :unauthorized}
  def exists?(%Scoped{subject: %Subject{account: %{id: account_id}} = subject}, queryable) do
    schema = get_schema_module(queryable)

    with :ok <- permit(:read, schema, subject) do
      queryable
      |> where(account_id: ^account_id)
      |> Repo.exists?()
    end
  end

  def exists?(repo, queryable) when repo == Repo, do: Repo.exists?(queryable)

  # Mutation operations
  @spec insert(Scoped.t(), Ecto.Changeset.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def insert(%Scoped{subject: subject}, %Ecto.Changeset{} = changeset) do
    changeset = %{changeset | action: :insert}
    schema = get_schema_module(changeset.data)

    with :ok <- permit(:insert, schema, subject) do
      changeset
      |> put_change(:account_id, subject.account.id)
      |> put_subject_trail(subject)
      |> Repo.insert()
    end
  end

  def insert(repo, changeset_or_struct, opts \\ []) when repo == Repo,
    do: Repo.insert(changeset_or_struct, opts)

  @spec update(Scoped.t(), Ecto.Changeset.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def update(%Scoped{subject: subject}, %Ecto.Changeset{} = changeset) do
    changeset = %{changeset | action: :update}
    schema = get_schema_module(changeset.data)

    with :ok <- permit(:update, schema, subject) do
      Repo.update(changeset)
    end
  end

  def update(repo, changeset, opts \\ []) when repo == Repo, do: Repo.update(changeset, opts)

  @spec delete(Scoped.t(), Ecto.Changeset.t() | Ecto.Schema.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def delete(
        %Scoped{subject: %Subject{account: %{id: account_id}} = subject},
        %Ecto.Changeset{data: %{account_id: account_id}} = changeset
      ) do
    changeset = %{changeset | action: :delete}
    schema = get_schema_module(changeset.data)

    with :ok <- permit(:delete, schema, subject) do
      Repo.delete(changeset)
    end
  end

  def delete(
        %Scoped{subject: %Subject{account: %{id: account_id}} = subject},
        %{account_id: account_id} = struct
      )
      when is_struct(struct) do
    schema = get_schema_module(struct)

    with :ok <- permit(:delete, schema, subject) do
      Repo.delete(struct)
    end
  end

  def delete(repo, struct_or_changeset, opts \\ []) when repo == Repo,
    do: Repo.delete(struct_or_changeset, opts)

  # Helper functions
  def get_schema_module(%Ecto.Query{from: %{source: {_table, schema}}}), do: schema
  def get_schema_module(%Ecto.Changeset{data: data}), do: get_schema_module(data)
  def get_schema_module(struct) when is_struct(struct), do: struct.__struct__
  def get_schema_module(module) when is_atom(module), do: module
  def get_schema_module(_), do: nil

  def permit(action, schema, %Subject{} = subject) do
    permit(action, schema, subject.actor.type)
  end

  def permit(_action, Domain.AuthProviders.AuthProvider, :account_admin_user), do: :ok
  def permit(_action, Domain.Entra.AuthProvider, :account_admin_user), do: :ok
  def permit(_action, Domain.Google.AuthProvider, :account_admin_user), do: :ok
  def permit(_action, Domain.Okta.AuthProvider, :account_admin_user), do: :ok
  def permit(_action, Domain.OIDC.AuthProvider, :account_admin_user), do: :ok
  def permit(_action, Domain.EmailOTP.AuthProvider, :account_admin_user), do: :ok
  def permit(_action, Domain.Userpass.AuthProvider, :account_admin_user), do: :ok
  def permit(_action, Domain.Entra.Directory, :account_admin_user), do: :ok
  def permit(_action, Domain.Google.Directory, :account_admin_user), do: :ok
  def permit(_action, Domain.Okta.Directory, :account_admin_user), do: :ok

  def permit(_action, _struct, _type), do: {:error, :unauthorized}

  def put_subject_trail(changeset, %Subject{} = subject) do
    changeset
    |> put_change(:created_by, :actor)
    |> put_change(:created_by_subject, %{
      "ip" => to_string(:inet.ntoa(subject.context.remote_ip)),
      "ip_region" => subject.context.remote_ip_location_region,
      "ip_city" => subject.context.remote_ip_location_city,
      "ip_lat" => subject.context.remote_ip_location_lat,
      "ip_lon" => subject.context.remote_ip_location_lon,
      "user_agent" => subject.context.user_agent,
      "email" => subject.actor.email,
      "id" => subject.actor.id
    })
  end
end
