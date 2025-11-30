defmodule Domain.Safe do
  @moduledoc """
    Centralized module to handle all DB operations requiring authorization checks.
  """

  import Ecto.Query, warn: false
  import Ecto.Changeset

  alias Domain.{Auth.Subject, Repo}

  defmodule Scoped do
    @moduledoc """
    Scoped context that carries authorization information and optional queryable.
    """
    @type t :: %__MODULE__{subject: Subject.t(), queryable: Ecto.Queryable.t() | nil}

    defstruct [:subject, :queryable]
  end

  defmodule Unscoped do
    @moduledoc """
    Unscoped context for operations without authorization.
    """
    @type t :: %__MODULE__{queryable: Ecto.Queryable.t() | nil}

    defstruct [:queryable]
  end

  @doc """
  Returns a scoped context for operations with authorization and account filtering.
  Can optionally accept a queryable to enable chaining.

  ## Examples

      # Traditional style
      Safe.scoped(subject) |> Safe.one(query)

      # Chainable style
      query |> Safe.scoped(subject) |> Safe.one()
  """
  @spec scoped(Subject.t()) :: Scoped.t()
  def scoped(%Subject{} = subject) do
    %Scoped{subject: subject, queryable: nil}
  end

  @spec scoped(Ecto.Queryable.t() | Ecto.Changeset.t(), Subject.t()) :: Scoped.t()
  def scoped(queryable, %Subject{} = subject) do
    %Scoped{subject: subject, queryable: queryable}
  end

  @doc """
  Returns an unscoped context for operations without authorization or filtering.
  Can optionally accept a queryable to enable chaining.

  ## Examples

      # Traditional style
      Safe.unscoped() |> Safe.one(query)

      # Chainable style
      query |> Safe.unscoped() |> Safe.one()
  """
  @spec unscoped() :: Unscoped.t()
  def unscoped do
    %Unscoped{queryable: nil}
  end

  @spec unscoped(Ecto.Queryable.t()) :: Unscoped.t()
  def unscoped(queryable) do
    %Unscoped{queryable: queryable}
  end

  # Query operations
  @spec one(Scoped.t()) :: Ecto.Schema.t() | nil | {:error, :unauthorized}
  def one(%Scoped{subject: %Subject{account: %{id: account_id}} = subject, queryable: queryable}) do
    schema = get_schema_module(queryable)

    with :ok <- permit(:read, schema, subject) do
      queryable
      |> apply_account_filter(schema, account_id)
      |> Repo.one()
    end
  end

  @spec one(Unscoped.t()) :: Ecto.Schema.t() | nil
  def one(%Unscoped{queryable: queryable}), do: Repo.one(queryable)

  @spec one(Domain.Repo, Ecto.Queryable.t()) :: Ecto.Schema.t() | nil
  def one(repo, queryable) when repo == Repo, do: Repo.one(queryable)

  @spec one!(Scoped.t()) :: Ecto.Schema.t() | no_return()
  def one!(%Scoped{subject: %Subject{account: %{id: account_id}} = subject, queryable: queryable}) do
    schema = get_schema_module(queryable)

    with :ok <- permit(:read, schema, subject) do
      queryable
      |> apply_account_filter(schema, account_id)
      |> Repo.one!()
    end
  end

  @spec one!(Unscoped.t()) :: Ecto.Schema.t() | no_return()
  def one!(%Unscoped{queryable: queryable}), do: Repo.one!(queryable)

  @spec one!(Domain.Repo, Ecto.Queryable.t()) :: Ecto.Schema.t() | no_return()
  def one!(repo, queryable) when repo == Repo, do: Repo.one!(queryable)

  @spec all(Scoped.t()) :: [Ecto.Schema.t()] | {:error, :unauthorized}
  def all(%Scoped{subject: %Subject{account: %{id: account_id}} = subject, queryable: queryable}) do
    schema = get_schema_module(queryable)

    with :ok <- permit(:read, schema, subject) do
      queryable
      |> apply_account_filter(schema, account_id)
      |> Repo.all()
    end
  end

  @spec all(Unscoped.t()) :: [Ecto.Schema.t()]
  def all(%Unscoped{queryable: queryable}), do: Repo.all(queryable)

  @spec all(Domain.Repo, Ecto.Queryable.t()) :: [Ecto.Schema.t()]
  def all(repo, queryable) when repo == Repo, do: Repo.all(queryable)

  @spec exists?(Scoped.t()) :: boolean() | {:error, :unauthorized}
  def exists?(%Scoped{
        subject: %Subject{account: %{id: account_id}} = subject,
        queryable: queryable
      }) do
    schema = get_schema_module(queryable)

    with :ok <- permit(:read, schema, subject) do
      queryable
      |> apply_account_filter(schema, account_id)
      |> Repo.exists?()
    end
  end

  @spec exists?(Unscoped.t()) :: boolean()
  def exists?(%Unscoped{queryable: queryable}), do: Repo.exists?(queryable)

  @spec exists?(Domain.Repo, Ecto.Queryable.t()) :: boolean()
  def exists?(repo, queryable) when repo == Repo, do: Repo.exists?(queryable)

  @doc """
  Lists records with pagination support.
  Requires a query_module that implements pagination callbacks.

  ## Examples
      Actor.Query.all()
      |> Safe.scoped(subject)
      |> Safe.list(Actor.Query, limit: 10)
  """
  @spec list(Scoped.t(), module(), Keyword.t()) ::
          {:ok, [Ecto.Schema.t()], map()} | {:error, :unauthorized}
  def list(
        %Scoped{subject: %Subject{account: %{id: account_id}} = subject, queryable: queryable},
        query_module,
        opts \\ []
      ) do
    schema = get_schema_module(queryable)

    with :ok <- permit(:read, schema, subject) do
      queryable
      |> apply_account_filter(schema, account_id)
      |> Repo.list(query_module, opts)
    end
  end

  @spec stream(Unscoped.t(), Keyword.t()) :: Enum.t()
  def stream(%Unscoped{queryable: queryable}, opts \\ []), do: Repo.stream(queryable, opts)

  @spec stream(Domain.Repo, Ecto.Queryable.t(), Keyword.t()) :: Enum.t()
  def stream(repo, queryable, opts) when repo == Repo, do: Repo.stream(queryable, opts)

  @spec aggregate(Unscoped.t(), atom()) :: term()
  def aggregate(%Unscoped{queryable: queryable}, aggregate),
    do: Repo.aggregate(queryable, aggregate)

  @spec aggregate(Unscoped.t(), atom(), atom()) :: term()
  def aggregate(%Unscoped{queryable: queryable}, aggregate, field),
    do: Repo.aggregate(queryable, aggregate, field)

  @spec load(module(), {list(), list()}) :: Ecto.Schema.t()
  def load(schema, data) when is_atom(schema), do: Repo.load(schema, data)

  @spec preload(Ecto.Schema.t() | [Ecto.Schema.t()], term()) ::
          Ecto.Schema.t() | [Ecto.Schema.t()]
  def preload(struct_or_structs, preloads), do: Repo.preload(struct_or_structs, preloads)

  @doc """
  Executes a transaction using either a function or an Ecto.Multi struct.

  ## Examples
      Safe.transact(fn -> ... end)

      Ecto.Multi.new()
      |> Ecto.Multi.insert(:user, changeset)
      |> Safe.transact()
  """
  def transact(fun_or_multi, opts \\ [])

  @spec transact((... -> any()), Keyword.t()) :: {:ok, any()} | {:error, any()}
  def transact(fun, opts) when is_function(fun), do: Repo.transact(fun, opts)

  @spec transact(Ecto.Multi.t(), Keyword.t()) :: {:ok, map()} | {:error, atom(), any(), map()}
  def transact(%Ecto.Multi{} = multi, opts), do: Repo.transact(multi, opts)

  @doc """
  Executes raw SQL query without authorization checks.
  The queryable field in Unscoped is ignored for this operation.

  ## Examples
      Safe.unscoped() |> Safe.query("SELECT * FROM actors WHERE id = $1", [actor_id])
  """
  @spec query(Unscoped.t(), String.t(), list()) ::
          {:ok, Postgrex.Result.t()} | {:error, Postgrex.Error.t()}
  def query(%Unscoped{}, sql, params) when is_binary(sql) and is_list(params) do
    Repo.query(sql, params)
  end

  @spec query(Domain.Repo, String.t(), list()) ::
          {:ok, Postgrex.Result.t()} | {:error, Postgrex.Error.t()}
  def query(repo, sql, params) when repo == Repo and is_binary(sql) and is_list(params) do
    Repo.query(sql, params)
  end

  @doc """
  Inserts multiple entries for the given schema.
  The queryable field in Scoped/Unscoped is ignored for this operation.

  ## Examples
      Safe.unscoped() |> Safe.insert_all(Actor, entries, on_conflict: :nothing)
      Safe.scoped(subject) |> Safe.insert_all(Actor, entries)
  """
  def insert_all(first_arg, schema_or_source, entries, opts \\ [])

  @spec insert_all(Scoped.t(), atom() | Ecto.Schema.t(), [map() | Keyword.t()], Keyword.t()) ::
          {integer(), nil | [term()]} | {:error, :unauthorized}
  def insert_all(%Scoped{subject: subject}, schema_or_source, entries, opts) do
    schema = if is_atom(schema_or_source), do: schema_or_source, else: schema_or_source.__struct__

    case permit(:insert_all, schema, subject) do
      :ok ->
        Repo.insert_all(schema_or_source, entries, opts)

      {:error, :unauthorized} ->
        {:error, :unauthorized}
    end
  end

  @spec insert_all(Unscoped.t(), atom() | Ecto.Schema.t(), [map() | Keyword.t()], Keyword.t()) ::
          {integer(), nil | [term()]}
  def insert_all(%Unscoped{}, schema_or_source, entries, opts) do
    Repo.insert_all(schema_or_source, entries, opts)
  end

  @spec insert_all(Domain.Repo, atom() | Ecto.Schema.t(), [map() | Keyword.t()], Keyword.t()) ::
          {integer(), nil | [term()]}
  def insert_all(repo, schema_or_source, entries, opts) when repo == Repo do
    Repo.insert_all(schema_or_source, entries, opts)
  end

  # Mutation operations
  @spec insert(Scoped.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def insert(%Scoped{subject: subject, queryable: %Ecto.Changeset{} = changeset}) do
    changeset = %{changeset | action: :insert}
    schema = get_schema_module(changeset.data)

    with :ok <- permit(:insert, schema, subject) do
      Repo.transaction(fn ->
        # Emit subject info to the replication stream
        emit_subject_message(subject, :insert, schema)

        changeset
        |> put_change(:account_id, subject.account.id)
        |> apply_schema_changeset(schema)
        |> Repo.insert!()
      end)
    end
  end

  @spec insert(Unscoped.t()) :: {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def insert(%Unscoped{queryable: %Ecto.Changeset{} = changeset}) do
    schema = get_schema_module(changeset.data)

    changeset
    |> apply_schema_changeset(schema)
    |> Repo.insert()
  end

  @spec insert(Domain.Repo, Ecto.Schema.t() | Ecto.Changeset.t(), Keyword.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def insert(repo, changeset_or_struct, opts \\ []) when repo == Repo do
    case changeset_or_struct do
      %Ecto.Changeset{} = changeset ->
        schema = get_schema_module(changeset.data)

        changeset
        |> apply_schema_changeset(schema)
        |> Repo.insert(opts)

      struct ->
        Repo.insert(struct, opts)
    end
  end

  @spec update(Scoped.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def update(%Scoped{subject: subject, queryable: %Ecto.Changeset{} = changeset}) do
    changeset = %{changeset | action: :update}
    schema = get_schema_module(changeset.data)

    with :ok <- permit(:update, schema, subject) do
      Repo.transaction(fn ->
        # Emit subject info to the replication stream
        emit_subject_message(subject, :update, schema)

        changeset
        |> apply_schema_changeset(schema)
        |> Repo.update!()
      end)
    end
  end

  @spec update(Unscoped.t()) :: {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def update(%Unscoped{queryable: %Ecto.Changeset{} = changeset}) do
    schema = get_schema_module(changeset.data)

    changeset
    |> apply_schema_changeset(schema)
    |> Repo.update()
  end

  @spec update(Domain.Repo, Ecto.Changeset.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  @spec update(Domain.Repo, Ecto.Changeset.t(), Keyword.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def update(repo, changeset, opts \\ []) when repo == Repo do
    schema = get_schema_module(changeset.data)

    changeset
    |> apply_schema_changeset(schema)
    |> Repo.update(opts)
  end

  @spec update_all(Scoped.t(), Keyword.t()) ::
          {non_neg_integer(), nil | [term()]} | {:error, :unauthorized}
  def update_all(%Scoped{subject: subject, queryable: queryable}, updates) do
    schema = get_schema_module(queryable)

    case permit(:update_all, schema, subject) do
      :ok ->
        Repo.transaction(fn ->
          # Emit subject info to the replication stream
          emit_subject_message(subject, :update_all, schema)

          Repo.update_all(queryable, updates)
        end)

      {:error, :unauthorized} ->
        {:error, :unauthorized}
    end
  end

  @spec update_all(Unscoped.t(), Keyword.t()) :: {non_neg_integer(), nil | [term()]}
  def update_all(%Unscoped{queryable: queryable}, updates) do
    Repo.update_all(queryable, updates)
  end

  @spec update_all(Domain.Repo, Ecto.Queryable.t(), Keyword.t()) ::
          {non_neg_integer(), nil | [term()]}
  def update_all(repo, queryable, updates) when repo == Repo do
    Repo.update_all(queryable, updates)
  end

  @spec delete(Scoped.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def delete(%Scoped{
        subject: %Subject{account: %{id: account_id}} = subject,
        queryable: %Ecto.Changeset{data: %{account_id: account_id}} = changeset
      }) do
    changeset = %{changeset | action: :delete}
    schema = get_schema_module(changeset.data)

    with :ok <- permit(:delete, schema, subject) do
      Repo.transaction(fn ->
        # Emit subject info to the replication stream
        emit_subject_message(subject, :delete, schema)

        changeset
        |> apply_schema_changeset(schema)
        |> Repo.delete()
      end)
      |> case do
        {:ok, result} -> result
        {:error, _} = error -> error
      end
    end
  end

  def delete(%Scoped{
        subject: %Subject{account: %{id: account_id}} = subject,
        queryable: %{account_id: account_id} = struct
      })
      when is_struct(struct) do
    schema = get_schema_module(struct)

    with :ok <- permit(:delete, schema, subject) do
      Repo.transaction(fn ->
        # Emit subject info to the replication stream
        emit_subject_message(subject, :delete, schema)

        Repo.delete(struct)
      end)
      |> case do
        {:ok, result} -> result
        {:error, _} = error -> error
      end
    end
  end

  @spec delete(Unscoped.t()) :: {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Unscoped{queryable: %Ecto.Changeset{} = changeset}) do
    schema = get_schema_module(changeset.data)

    changeset
    |> apply_schema_changeset(schema)
    |> Repo.delete()
  end

  def delete(%Unscoped{queryable: struct}) when is_struct(struct) do
    Repo.delete(struct)
  end

  @spec delete(Domain.Repo, Ecto.Schema.t() | Ecto.Changeset.t(), Keyword.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def delete(repo, struct_or_changeset, opts \\ []) when repo == Repo do
    case struct_or_changeset do
      %Ecto.Changeset{} = changeset ->
        schema = get_schema_module(changeset.data)

        changeset
        |> apply_schema_changeset(schema)
        |> Repo.delete(opts)

      struct ->
        Repo.delete(struct, opts)
    end
  end

  # Header with defaults
  def delete_all(scoped_or_unscoped, opts \\ [])

  @spec delete_all(Scoped.t(), Keyword.t()) ::
          {integer(), nil | [term()]} | {:error, :unauthorized}
  def delete_all(%Scoped{subject: subject, queryable: queryable}, opts) do
    schema = get_schema_module(queryable)

    case permit(:delete_all, schema, subject) do
      :ok ->
        Repo.transaction(fn ->
          # Emit subject info to the replication stream
          emit_subject_message(subject, :delete_all, schema)

          {deleted_count, result} = Repo.delete_all(queryable, opts)
          {deleted_count, result}
        end)
        |> case do
          {:ok, result} -> result
          {:error, _} = error -> error
        end

      {:error, :unauthorized} ->
        {:error, :unauthorized}
    end
  end

  @spec delete_all(Unscoped.t(), Keyword.t()) ::
          {integer(), nil | [term()]}
  def delete_all(%Unscoped{queryable: queryable}, opts) when not is_nil(queryable) do
    Repo.delete_all(queryable, opts)
  end

  # Overloaded version for when Unscoped has nil queryable
  def delete_all(%Unscoped{queryable: nil}, queryable, opts) do
    Repo.delete_all(queryable, opts)
  end

  # Helper functions
  defp apply_account_filter(queryable, Domain.Account, account_id) do
    # For Account schema, filter by id instead of account_id
    where(queryable, id: ^account_id)
  end

  defp apply_account_filter(queryable, _schema, account_id) do
    # For all other schemas, filter by account_id
    where(queryable, account_id: ^account_id)
  end

  defp apply_schema_changeset(changeset, schema) do
    if function_exported?(schema, :changeset, 1) do
      schema.changeset(changeset)
    else
      changeset
    end
  end

  def get_schema_module(%Ecto.Query{from: %{source: {_table, schema}}}), do: schema
  def get_schema_module(%Ecto.Changeset{data: data}), do: get_schema_module(data)
  def get_schema_module(struct) when is_struct(struct), do: struct.__struct__
  def get_schema_module(module) when is_atom(module), do: module
  def get_schema_module(_), do: nil

  def permit(action, schema, %Subject{} = subject) do
    permit(action, schema, subject.actor.type)
  end

  def permit(_action, Domain.Account, :account_admin_user), do: :ok
  def permit(:read, Domain.Account, :account_user), do: :ok
  def permit(:read, Domain.Account, :service_account), do: :ok
  def permit(:read, Domain.Account, :api_client), do: :ok
  def permit(_action, Domain.Actor, :account_admin_user), do: :ok
  def permit(_action, Domain.Actors.Group, :account_admin_user), do: :ok
  def permit(_action, Domain.ExternalIdentity, :account_admin_user), do: :ok
  def permit(_action, Domain.Tokens.Token, :account_admin_user), do: :ok
  def permit(_action, Domain.Directory, :account_admin_user), do: :ok
  def permit(_action, Domain.AuthProvider, :account_admin_user), do: :ok
  def permit(_action, Domain.Entra.AuthProvider, :account_admin_user), do: :ok
  def permit(_action, Domain.Google.AuthProvider, :account_admin_user), do: :ok
  def permit(_action, Domain.Okta.AuthProvider, :account_admin_user), do: :ok
  def permit(_action, Domain.OIDC.AuthProvider, :account_admin_user), do: :ok
  def permit(_action, Domain.EmailOTP.AuthProvider, :account_admin_user), do: :ok
  def permit(_action, Domain.Userpass.AuthProvider, :account_admin_user), do: :ok
  def permit(_action, Domain.Entra.Directory, :account_admin_user), do: :ok
  def permit(_action, Domain.Google.Directory, :account_admin_user), do: :ok
  def permit(_action, Domain.Okta.Directory, :account_admin_user), do: :ok

  # Client permissions
  def permit(_action, Domain.Client, :account_admin_user), do: :ok
  def permit(:read, Domain.Client, :account_user), do: :ok
  def permit(:update, Domain.Client, :account_user), do: :ok
  def permit(:read, Domain.Client, :service_account), do: :ok
  def permit(:update, Domain.Client, :service_account), do: :ok

  # Flow permissions - all actor types can read and create flows
  def permit(:read, Domain.Flows.Flow, _), do: :ok
  def permit(:insert, Domain.Flows.Flow, _), do: :ok
  # Only admin can manage/delete flows
  def permit(_action, Domain.Flows.Flow, :account_admin_user), do: :ok

  # Gateway permissions
  def permit(_action, Domain.Gateway, :account_admin_user), do: :ok
  def permit(:read, Domain.Gateway, _), do: :ok

  # Site permissions
  def permit(_action, Domain.Site, :account_admin_user), do: :ok
  def permit(:read, Domain.Site, _), do: :ok

  # Resource permissions
  def permit(_action, Domain.Resource, :account_admin_user), do: :ok
  def permit(:read, Domain.Resource, _), do: :ok

  # Resource Connection permissions
  def permit(_action, Domain.Resources.Connection, :account_admin_user), do: :ok

  # Policy permissions
  def permit(_action, Domain.Policies.Policy, :account_admin_user), do: :ok
  def permit(:read, Domain.Policies.Policy, _), do: :ok

  # Relay permissions
  def permit(_action, Domain.Relays.Relay, :account_admin_user), do: :ok
  def permit(:read, Domain.Relays.Relay, _), do: :ok

  # Relay Group permissions
  def permit(_action, Domain.Relays.Group, :account_admin_user), do: :ok
  def permit(:read, Domain.Relays.Group, _), do: :ok

  def permit(_action, _struct, _type), do: {:error, :unauthorized}

  # Helper function to emit subject information to the replication stream
  defp emit_subject_message(%Subject{} = subject, _operation, _schema) do
    subject_info = %{
      "ip" => to_string(:inet.ntoa(subject.context.remote_ip)),
      "ip_region" => subject.context.remote_ip_location_region,
      "ip_city" => subject.context.remote_ip_location_city,
      "ip_lat" => subject.context.remote_ip_location_lat,
      "ip_lon" => subject.context.remote_ip_location_lon,
      "user_agent" => subject.context.user_agent,
      "actor_name" => subject.actor.name,
      "actor_type" => to_string(subject.actor.type),
      "actor_email" => subject.actor.email,
      "actor_id" => subject.actor.id,
      "auth_provider_id" => subject.auth_provider_id
    }

    message = JSON.encode!(subject_info)
    Repo.query!("SELECT pg_logical_emit_message(true, 'subject', $1)", [message])
  end
end
