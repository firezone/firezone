defmodule Portal.Safe do
  @moduledoc """
    Centralized module to handle all DB operations requiring authorization checks.
  """

  import Ecto.Query, warn: false
  import Ecto.Changeset
  require Logger

  alias Portal.{Authentication.Subject, Repo}

  defmodule Scoped do
    @moduledoc """
    Scoped context that carries authorization information and optional queryable.
    """
    @type t :: %__MODULE__{
            subject: Subject.t(),
            queryable: Ecto.Queryable.t() | Ecto.Changeset.t() | Ecto.Schema.t() | nil,
            repo: module()
          }

    defstruct [:subject, :queryable, repo: Portal.Repo]
  end

  defmodule Unscoped do
    @moduledoc """
    Unscoped context for operations without authorization.
    """
    @type t :: %__MODULE__{
            queryable: Ecto.Queryable.t() | Ecto.Changeset.t() | Ecto.Schema.t() | nil,
            repo: module()
          }

    defstruct [:queryable, repo: Portal.Repo]
  end

  @doc """
  Returns a scoped context for operations with authorization and account filtering.
  Can optionally accept a queryable to enable chaining and a repo module.

  ## Examples

      # Traditional style
      Safe.scoped(subject) |> Safe.one(query)

      # Chainable style
      query |> Safe.scoped(subject) |> Safe.one()

      # With an isolated pool
      Safe.scoped(subject, Repo.Poller) |> Safe.one(query)
  """
  @spec scoped(Subject.t()) :: Scoped.t()
  def scoped(%Subject{} = subject) do
    %Scoped{subject: subject, queryable: nil, repo: Repo}
  end

  @spec scoped(Subject.t(), module()) :: Scoped.t()
  def scoped(%Subject{} = subject, repo) when is_atom(repo) do
    %Scoped{subject: subject, queryable: nil, repo: repo}
  end

  @spec scoped(Ecto.Queryable.t() | Ecto.Changeset.t() | Ecto.Schema.t(), Subject.t()) ::
          Scoped.t()
  def scoped(queryable, %Subject{} = subject) do
    %Scoped{subject: subject, queryable: queryable, repo: Repo}
  end

  @spec scoped(
          Ecto.Queryable.t() | Ecto.Changeset.t() | Ecto.Schema.t(),
          Subject.t(),
          module()
        ) ::
          Scoped.t()
  def scoped(queryable, %Subject{} = subject, repo) when is_atom(repo) do
    %Scoped{subject: subject, queryable: queryable, repo: repo}
  end

  @doc """
  Returns an unscoped context for operations without authorization or filtering.
  Can optionally accept a queryable to enable chaining and a repo module.

  ## Examples

      # Traditional style
      Safe.unscoped() |> Safe.one(query)

      # Chainable style
      query |> Safe.unscoped() |> Safe.one()

      # With an isolated pool
      Safe.unscoped(Repo.Poller) |> Safe.one(query)
  """
  @spec unscoped() :: Unscoped.t()
  def unscoped do
    %Unscoped{queryable: nil, repo: Repo}
  end

  @spec unscoped(module() | Ecto.Queryable.t() | Ecto.Changeset.t() | Ecto.Schema.t()) ::
          Unscoped.t()
  # A bare schema module is an atom too, so it would otherwise be taken for a repo
  def unscoped(queryable_or_repo) when is_atom(queryable_or_repo) do
    if ecto_schema?(queryable_or_repo) do
      %Unscoped{queryable: queryable_or_repo, repo: Repo}
    else
      %Unscoped{queryable: nil, repo: queryable_or_repo}
    end
  end

  def unscoped(queryable) do
    %Unscoped{queryable: queryable, repo: Repo}
  end

  @spec unscoped(Ecto.Queryable.t() | Ecto.Changeset.t() | Ecto.Schema.t(), module()) ::
          Unscoped.t()
  def unscoped(queryable, repo) when is_atom(repo) do
    %Unscoped{queryable: queryable, repo: repo}
  end

  # Query operations

  @spec one(Scoped.t()) :: Ecto.Schema.t() | nil | {:error, :unauthorized}
  def one(%Scoped{
        subject: %Subject{account: %{id: account_id}} = subject,
        queryable: queryable,
        repo: repo
      }) do
    schema = get_schema_module(queryable)

    with :ok <- permit(:read, schema, subject) do
      filtered_query = apply_account_filter(queryable, schema, account_id)
      safe_repo(fn -> repo.one(filtered_query) end)
    end
  end

  @spec one(Unscoped.t()) :: Ecto.Schema.t() | nil
  def one(%Unscoped{queryable: queryable, repo: repo}),
    do: safe_repo(fn -> repo.one(queryable) end)

  @spec one(Portal.Repo, Ecto.Queryable.t()) :: Ecto.Schema.t() | nil
  def one(repo, queryable) when repo == Repo, do: safe_repo(fn -> Repo.one(queryable) end)

  @spec one!(Scoped.t()) ::
          Ecto.Schema.t() | term() | no_return() | {:error, :unauthorized}
  def one!(%Scoped{
        subject: %Subject{account: %{id: account_id}} = subject,
        queryable: queryable,
        repo: repo
      }) do
    schema = get_schema_module(queryable)

    with :ok <- permit(:read, schema, subject) do
      filtered_query = apply_account_filter(queryable, schema, account_id)
      safe_repo!(fn -> repo.one!(filtered_query) end, filtered_query)
    end
  end

  @spec one!(Unscoped.t()) :: Ecto.Schema.t() | term() | no_return()
  def one!(%Unscoped{queryable: queryable, repo: repo}),
    do: safe_repo!(fn -> repo.one!(queryable) end, queryable)

  @spec one!(Portal.Repo, Ecto.Queryable.t()) :: Ecto.Schema.t() | term() | no_return()
  def one!(repo, queryable) when repo == Repo,
    do: safe_repo!(fn -> Repo.one!(queryable) end, queryable)

  @spec all(Scoped.t()) :: [Ecto.Schema.t()] | {:error, :unauthorized}
  def all(%Scoped{
        subject: %Subject{account: %{id: account_id}} = subject,
        queryable: queryable,
        repo: repo
      }) do
    schema = get_schema_module(queryable)

    with :ok <- permit(:read, schema, subject) do
      filtered_query = apply_account_filter(queryable, schema, account_id)
      safe_repo(fn -> repo.all(filtered_query) end) || []
    end
  end

  @spec all(Unscoped.t()) :: [Ecto.Schema.t()]
  def all(%Unscoped{queryable: queryable, repo: repo}),
    do: safe_repo(fn -> repo.all(queryable) end) || []

  @spec all(Portal.Repo, Ecto.Queryable.t()) :: [Ecto.Schema.t()]
  def all(repo, queryable) when repo == Repo, do: safe_repo(fn -> Repo.all(queryable) end) || []

  @spec exists?(Scoped.t()) :: boolean() | {:error, :unauthorized}
  def exists?(%Scoped{
        subject: %Subject{account: %{id: account_id}} = subject,
        queryable: queryable,
        repo: repo
      }) do
    schema = get_schema_module(queryable)

    with :ok <- permit(:read, schema, subject) do
      filtered_query = apply_account_filter(queryable, schema, account_id)
      safe_repo(fn -> repo.exists?(filtered_query) end) || false
    end
  end

  @spec exists?(Unscoped.t()) :: boolean()
  def exists?(%Unscoped{queryable: queryable, repo: repo}),
    do: safe_repo(fn -> repo.exists?(queryable) end) || false

  @spec exists?(Portal.Repo, Ecto.Queryable.t()) :: boolean()
  def exists?(repo, queryable) when repo == Repo,
    do: safe_repo(fn -> Repo.exists?(queryable) end) || false

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
        %Scoped{
          subject: %Subject{account: %{id: account_id}} = subject,
          queryable: queryable,
          repo: repo
        },
        query_module,
        opts \\ []
      ) do
    schema = get_schema_module(queryable)

    with :ok <- permit(:read, schema, subject) do
      safe_repo(fn ->
        queryable
        |> apply_account_filter(schema, account_id)
        |> repo.list(query_module, opts)
      end) || {:ok, [], Portal.Repo.Paginator.empty_metadata()}
    end
  end

  @spec list_offset(Scoped.t(), module(), Keyword.t()) ::
          {:ok, [Ecto.Schema.t()], map()} | {:error, :unauthorized}
  def list_offset(
        %Scoped{
          subject: %Subject{account: %{id: account_id}} = subject,
          queryable: queryable,
          repo: repo
        },
        query_module,
        opts \\ []
      ) do
    schema = get_schema_module(queryable)

    with :ok <- permit(:read, schema, subject) do
      safe_repo(fn ->
        queryable
        |> apply_account_filter(schema, account_id)
        |> repo.list_offset(query_module, opts)
      end) || {:ok, [], %{}}
    end
  end

  @spec stream(Unscoped.t(), Keyword.t()) :: Enum.t()
  def stream(%Unscoped{queryable: queryable, repo: repo}, opts \\ []),
    do: repo.stream(queryable, opts)

  @spec stream(Portal.Repo, Ecto.Queryable.t(), Keyword.t()) :: Enum.t()
  def stream(repo, queryable, opts) when repo == Repo, do: Repo.stream(queryable, opts)

  @spec aggregate(Scoped.t(), atom()) :: term() | {:error, :unauthorized}
  def aggregate(
        %Scoped{
          subject: %Subject{account: %{id: account_id}} = subject,
          queryable: queryable,
          repo: repo
        },
        aggregate
      ) do
    schema = get_schema_module(queryable)

    with :ok <- permit(:read, schema, subject) do
      safe_repo(fn ->
        queryable
        |> apply_account_filter(schema, account_id)
        |> repo.aggregate(aggregate)
      end) || 0
    end
  end

  @spec aggregate(Unscoped.t(), atom()) :: term()
  def aggregate(%Unscoped{queryable: queryable, repo: repo}, aggregate),
    do: safe_repo(fn -> repo.aggregate(queryable, aggregate) end) || 0

  @spec aggregate(Unscoped.t(), atom(), atom()) :: term()
  def aggregate(%Unscoped{queryable: queryable, repo: repo}, aggregate, field),
    do: safe_repo(fn -> repo.aggregate(queryable, aggregate, field) end) || 0

  @spec load(module(), {list(), list()}) :: Ecto.Schema.t()
  def load(schema, data) when is_atom(schema), do: Repo.load(schema, data)

  @spec preload(Ecto.Schema.t() | [Ecto.Schema.t()], term(), module()) ::
          Ecto.Schema.t() | [Ecto.Schema.t()]
  def preload(struct_or_structs, preloads, repo \\ Repo) when is_atom(repo),
    do: repo.preload(struct_or_structs, preloads)

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
  def transact(multi, opts) when is_struct(multi, Ecto.Multi), do: Repo.transact(multi, opts)

  @doc """
  Executes raw SQL query without authorization checks.
  The queryable field in Unscoped is ignored for this operation.

  ## Examples
      Safe.unscoped() |> Safe.query("SELECT * FROM actors WHERE id = $1", [actor_id])
      Safe.unscoped(Repo.Poller) |> Safe.query("SELECT pg_try_advisory_lock($1)", [key])
  """
  @spec query(Unscoped.t(), String.t(), list()) ::
          {:ok, Postgrex.Result.t()} | {:error, Exception.t()}
  # sobelow_skip ["SQL.Query"]
  def query(%Unscoped{repo: repo}, sql, params) when is_binary(sql) and is_list(params) do
    repo.query(sql, params)
  end

  @spec query(Portal.Repo, String.t(), list()) ::
          {:ok, Postgrex.Result.t()} | {:error, Exception.t()}
  # sobelow_skip ["SQL.Query"]
  def query(repo, sql, params) when repo == Repo and is_binary(sql) and is_list(params) do
    Repo.query(sql, params)
  end

  @doc """
  Runs a function inside a database transaction without subject scoping.

  The function must return `{:ok, value}` or `{:error, reason}`; an error
  return rolls the transaction back.

  ## Examples
      Safe.unscoped() |> Safe.transaction(fn -> {:ok, ...} end)
  """
  @spec transaction(Unscoped.t(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def transaction(%Unscoped{}, fun) when is_function(fun, 0) do
    Repo.transact(fun)
  end

  @doc """
  Runs a function with a single connection checked out from the context's
  repo, without wrapping it in a transaction. All of that repo's queries
  inside `fun` use that connection, which session-scoped state (such as
  advisory locks) requires.

  ## Examples
      Safe.unscoped() |> Safe.checkout(fn -> ... end)
      Safe.unscoped(Repo.Poller) |> Safe.checkout(fn -> ... end, timeout: :timer.hours(24))
  """
  @spec checkout(Unscoped.t(), (-> term()), keyword()) :: term()
  def checkout(%Unscoped{repo: repo}, fun, opts \\ []) when is_function(fun, 0) do
    repo.checkout(fun, opts)
  end

  @doc """
  Inserts multiple entries for the given schema.
  The queryable field in Scoped/Unscoped is ignored for this operation.

  Scoped inserts stamp the subject's `account_id` on every entry and refuse an
  entry that names another account. Entries that span accounts, and the query
  form of `entries`, require `unscoped/0`.

  ## Examples
      Safe.unscoped() |> Safe.insert_all(Actor, entries, on_conflict: :nothing)
      Safe.scoped(subject) |> Safe.insert_all(Actor, entries)
  """
  def insert_all(first_arg, schema_or_source, entries, opts \\ [])

  @spec insert_all(
          Scoped.t(),
          atom() | Ecto.Schema.t(),
          [map() | Keyword.t()] | Ecto.Query.t(),
          Keyword.t()
        ) ::
          {integer(), nil | [term()]} | {:error, :unauthorized}
  def insert_all(%Scoped{subject: subject}, schema_or_source, entries, opts) do
    schema = if is_atom(schema_or_source), do: schema_or_source, else: schema_or_source.__struct__

    with :ok <- permit(:insert_all, schema, subject),
         {:ok, entries} <- scope_entries(entries, subject.account.id) do
      {:ok, result} =
        Repo.transact(fn ->
          emit_subject_message(subject)

          {:ok, Repo.insert_all(schema_or_source, entries, opts)}
        end)

      result
    end
  end

  @spec insert_all(
          Unscoped.t(),
          atom() | Ecto.Schema.t(),
          [map() | Keyword.t()] | Ecto.Query.t(),
          Keyword.t()
        ) ::
          {integer(), nil | [term()]}
  def insert_all(%Unscoped{}, schema_or_source, entries, opts) do
    Repo.insert_all(schema_or_source, entries, opts)
  end

  @spec insert_all(Portal.Repo, atom() | Ecto.Schema.t(), [map() | Keyword.t()], Keyword.t()) ::
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
      Repo.transact(fn ->
        emit_subject_message(subject)

        changeset
        |> put_change(:account_id, subject.account.id)
        |> apply_schema_changeset(schema)
        |> Repo.insert()
      end)
    end
  end

  def insert(%Scoped{subject: subject, queryable: struct}) when is_struct(struct) do
    schema = get_schema_module(struct)

    with :ok <- permit(:insert, schema, subject) do
      Repo.transact(fn ->
        emit_subject_message(subject)

        %{struct | account_id: subject.account.id}
        |> Repo.insert()
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

  def insert(%Unscoped{queryable: struct}) when is_struct(struct) do
    struct
    |> Repo.insert()
  end

  @spec insert(Portal.Repo, Ecto.Schema.t() | Ecto.Changeset.t(), Keyword.t()) ::
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
      Repo.transact(fn ->
        emit_subject_message(subject)

        changeset
        |> apply_schema_changeset(schema)
        |> Repo.update()
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

  @spec update(Portal.Repo, Ecto.Changeset.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  @spec update(Portal.Repo, Ecto.Changeset.t(), Keyword.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def update(repo, changeset, opts \\ []) when repo == Repo do
    schema = get_schema_module(changeset.data)

    changeset
    |> apply_schema_changeset(schema)
    |> Repo.update(opts)
  end

  @spec update_all(Scoped.t(), Keyword.t()) ::
          {non_neg_integer(), nil | [term()]} | {:error, :unauthorized}
  def update_all(
        %Scoped{
          subject: %Subject{account: %{id: account_id}} = subject,
          queryable: queryable
        },
        updates
      ) do
    schema = get_schema_module(queryable)

    case permit(:update_all, schema, subject) do
      :ok ->
        {:ok, result} =
          Repo.transact(fn ->
            emit_subject_message(subject)

            filtered_query = apply_account_filter(queryable, schema, account_id)

            {:ok, Repo.update_all(filtered_query, updates)}
          end)

        result

      {:error, :unauthorized} ->
        {:error, :unauthorized}
    end
  end

  @spec update_all(Unscoped.t(), Keyword.t()) :: {non_neg_integer(), nil | [term()]}
  def update_all(%Unscoped{queryable: queryable}, updates) do
    Repo.update_all(queryable, updates)
  end

  @spec delete(Scoped.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t() | :unauthorized | :not_found}
  def delete(%Scoped{
        subject: %Subject{account: %{id: account_id}} = subject,
        queryable: %Ecto.Changeset{data: %{account_id: account_id}} = changeset
      }) do
    changeset = %{changeset | action: :delete}
    schema = get_schema_module(changeset.data)

    with :ok <- permit(:delete, schema, subject) do
      Repo.transact(fn ->
        emit_subject_message(subject)

        changeset
        |> apply_schema_changeset(schema)
        |> Repo.delete()
      end)
    end
  rescue
    Ecto.StaleEntryError -> {:error, :not_found}
  end

  def delete(%Scoped{
        subject: %Subject{account: %{id: account_id}} = subject,
        queryable: %{account_id: account_id} = struct
      })
      when is_struct(struct) do
    schema = get_schema_module(struct)

    with :ok <- permit(:delete, schema, subject) do
      Repo.transact(fn ->
        emit_subject_message(subject)

        Repo.delete(struct)
      end)
    end
  rescue
    # The row went away between the caller's fetch and this delete.
    Ecto.StaleEntryError -> {:error, :not_found}
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

  @spec delete(Portal.Repo, Ecto.Schema.t() | Ecto.Changeset.t(), Keyword.t()) ::
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
  def delete_all(
        %Scoped{
          subject: %Subject{account: %{id: account_id}} = subject,
          queryable: queryable
        },
        opts
      ) do
    schema = get_schema_module(queryable)

    case permit(:delete_all, schema, subject) do
      :ok ->
        {:ok, result} =
          Repo.transact(fn ->
            emit_subject_message(subject)

            filtered_query = apply_account_filter(queryable, schema, account_id)
            {:ok, Repo.delete_all(filtered_query, opts)}
          end)

        result

      {:error, :unauthorized} ->
        {:error, :unauthorized}
    end
  end

  @spec delete_all(Unscoped.t(), Keyword.t()) ::
          {integer(), nil | [term()]}

  def delete_all(%Unscoped{queryable: queryable}, opts) do
    Repo.delete_all(queryable, opts)
  end

  # Helper functions

  defp safe_repo(fun) when is_function(fun, 0) do
    fun.()
  rescue
    error in Ecto.Query.CastError ->
      Logger.info("Query cast error", error: error)
      nil

    error in Ecto.CastError ->
      Logger.info("Cast error", error: error)
      nil

    error in ArgumentError ->
      Logger.info("Argument error", error: error)
      nil
  end

  defp safe_repo!(fun, queryable) when is_function(fun, 0) do
    fun.()
  rescue
    error in Ecto.Query.CastError ->
      Logger.info("Query cast error", error: error)
      reraise Ecto.NoResultsError, [queryable: queryable], __STACKTRACE__

    error in Ecto.CastError ->
      Logger.info("Cast error", error: error)
      reraise Ecto.NoResultsError, [queryable: queryable], __STACKTRACE__

    error in ArgumentError ->
      Logger.info("Argument error", error: error)
      reraise Ecto.NoResultsError, [queryable: queryable], __STACKTRACE__
  end

  defp ecto_schema?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1)
  end

  defp apply_account_filter(queryable, Portal.Account, account_id) do
    # For Account schema, filter by id instead of account_id
    where(queryable, id: ^account_id)
  end

  defp apply_account_filter(queryable, _schema, account_id) do
    # For all other schemas, filter by account_id
    where(queryable, account_id: ^account_id)
  end

  # Bulk inserts get the same treatment `insert/1` gives a changeset: the
  # subject's account is stamped on, and an entry naming another account is
  # refused. Cross-account inserts must say so with `unscoped/0`.
  defp scope_entries(entries, account_id) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, scoped} ->
      case scope_entry(entry, account_id) do
        {:ok, entry} -> {:cont, {:ok, [entry | scoped]}}
        {:error, :unauthorized} -> {:halt, {:error, :unauthorized}}
      end
    end)
    |> case do
      {:ok, scoped} -> {:ok, Enum.reverse(scoped)}
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
  end

  defp scope_entries(_query, _account_id), do: {:error, :unauthorized}

  defp scope_entry(entry, account_id) when is_map(entry) do
    case Map.fetch(entry, :account_id) do
      {:ok, ^account_id} -> {:ok, entry}
      {:ok, _other} -> {:error, :unauthorized}
      :error -> {:ok, Map.put(entry, :account_id, account_id)}
    end
  end

  defp scope_entry(entry, account_id) when is_list(entry) do
    case Keyword.fetch(entry, :account_id) do
      {:ok, ^account_id} -> {:ok, entry}
      {:ok, _other} -> {:error, :unauthorized}
      :error -> {:ok, Keyword.put(entry, :account_id, account_id)}
    end
  end

  defp apply_schema_changeset(changeset, schema) do
    changeset =
      if function_exported?(schema, :changeset, 1) do
        schema.changeset(changeset)
      else
        changeset
      end

    if function_exported?(schema, :__schema__, 1) do
      validate_binary_id_changes(changeset, schema)
    else
      changeset
    end
  end

  defp validate_binary_id_changes(changeset, schema) do
    changeset
    |> validate_current_binary_id_changes(schema)
    |> validate_nested_binary_id_changes()
  end

  defp validate_current_binary_id_changes(changeset, schema) do
    binary_id_fields(schema)
    |> Enum.reduce(changeset, &validate_binary_id_field(&2, &1))
  end

  defp validate_binary_id_field(changeset, field) do
    case fetch_change(changeset, field) do
      {:ok, nil} ->
        changeset

      {:ok, value} ->
        if valid_binary_id_change?(value) or has_invalid_error?(changeset, field) do
          changeset
        else
          add_error(changeset, field, "is invalid", validation: :binary_id)
        end

      :error ->
        changeset
    end
  end

  defp validate_nested_binary_id_changes(changeset) do
    Enum.reduce(changeset.changes, changeset, fn {field, value}, changeset ->
      validated_value = validate_nested_change(value)

      if validated_value == value do
        changeset
      else
        put_change(changeset, field, validated_value)
      end
    end)
  end

  defp validate_nested_change(%Ecto.Changeset{} = nested_changeset) do
    schema = get_schema_module(nested_changeset.data)

    if function_exported?(schema, :__schema__, 1) do
      validate_binary_id_changes(nested_changeset, schema)
    else
      nested_changeset
    end
  end

  defp validate_nested_change(list) when is_list(list) do
    Enum.map(list, &validate_nested_change/1)
  end

  defp validate_nested_change(value), do: value

  defp binary_id_fields(schema) do
    Enum.filter(schema.__schema__(:fields), fn field ->
      schema.__schema__(:type, field) == :binary_id
    end)
  end

  defp valid_binary_id_change?(value) do
    match?({:ok, _}, Ecto.UUID.cast(value))
  end

  defp has_invalid_error?(changeset, field) do
    Enum.any?(changeset.errors, fn
      {^field, {_message, opts}} when is_list(opts) -> opts[:validation] == :binary_id
      _ -> false
    end)
  end

  def get_schema_module(%Ecto.Query{from: %{source: {_table, schema}}}), do: schema
  def get_schema_module(%Ecto.Changeset{data: data}), do: get_schema_module(data)
  def get_schema_module(struct) when is_struct(struct), do: struct.__struct__
  def get_schema_module(module) when is_atom(module), do: module
  def get_schema_module(_), do: nil

  def permit(action, schema, %Subject{} = subject) do
    permit(action, schema, subject.actor.type)
  end

  # Account permissions
  def permit(_action, Portal.Account, :account_admin_user), do: :ok
  def permit(:read, Portal.Account, :api_client), do: :ok
  def permit(:read, Portal.Account, :account_user), do: :ok
  def permit(:read, Portal.Account, :service_account), do: :ok
  # Admin-only permissions (both account_admin_user and api_client)
  def permit(_action, Portal.Actor, :account_admin_user), do: :ok
  def permit(_action, Portal.Actor, :api_client), do: :ok
  def permit(_action, Portal.Group, :account_admin_user), do: :ok
  def permit(_action, Portal.Group, :api_client), do: :ok
  def permit(:read, Portal.Group, :account_user), do: :ok
  def permit(_action, Portal.ExternalIdentity, :account_admin_user), do: :ok
  def permit(_action, Portal.ExternalIdentity, :api_client), do: :ok
  def permit(_action, Portal.ClientToken, :account_admin_user), do: :ok
  def permit(_action, Portal.ClientToken, :api_client), do: :ok
  def permit(_action, Portal.APIToken, :account_admin_user), do: :ok

  # OAuth grants and codes are created by a person going through the browser
  # consent screen, so they follow whoever signed in. A non-admin may connect a
  # client; the token they get can only do what their own actor may do.
  def permit(_action, Portal.OAuthGrant, :account_admin_user), do: :ok
  def permit(_action, Portal.OAuthGrant, :account_user), do: :ok
  def permit(_action, Portal.OAuthAuthorizationCode, :account_admin_user), do: :ok
  def permit(_action, Portal.OAuthAuthorizationCode, :account_user), do: :ok
  def permit(:read, Portal.OAuthToken, :account_admin_user), do: :ok
  def permit(:read, Portal.OAuthToken, :account_user), do: :ok
  def permit(_action, Portal.Directory, :account_admin_user), do: :ok
  def permit(:read, Portal.Directory, :api_client), do: :ok
  def permit(_action, Portal.AuthProvider, :account_admin_user), do: :ok
  def permit(:read, Portal.AuthProvider, :api_client), do: :ok
  def permit(_action, Portal.Entra.AuthProvider, :account_admin_user), do: :ok
  def permit(:read, Portal.Entra.AuthProvider, :api_client), do: :ok
  def permit(_action, Portal.Google.AuthProvider, :account_admin_user), do: :ok
  def permit(:read, Portal.Google.AuthProvider, :api_client), do: :ok
  def permit(_action, Portal.Okta.AuthProvider, :account_admin_user), do: :ok
  def permit(:read, Portal.Okta.AuthProvider, :api_client), do: :ok
  def permit(_action, Portal.OIDC.AuthProvider, :account_admin_user), do: :ok
  def permit(:read, Portal.OIDC.AuthProvider, :api_client), do: :ok
  def permit(_action, Portal.EmailOTP.AuthProvider, :account_admin_user), do: :ok
  def permit(:read, Portal.EmailOTP.AuthProvider, :api_client), do: :ok
  def permit(_action, Portal.Userpass.AuthProvider, :account_admin_user), do: :ok
  def permit(:read, Portal.Userpass.AuthProvider, :api_client), do: :ok
  def permit(_action, Portal.X509.AuthProvider, :account_admin_user), do: :ok
  def permit(:read, Portal.X509.AuthProvider, :api_client), do: :ok
  def permit(_action, Portal.Entra.Directory, :account_admin_user), do: :ok
  def permit(:read, Portal.Entra.Directory, :api_client), do: :ok
  def permit(_action, Portal.PostureProvider, :account_admin_user), do: :ok
  def permit(:read, Portal.PostureProvider, :api_client), do: :ok
  def permit(_action, Portal.Intune.PostureProvider, :account_admin_user), do: :ok
  def permit(:read, Portal.Intune.PostureProvider, :api_client), do: :ok
  def permit(:read, Portal.Intune.Device, :account_admin_user), do: :ok
  def permit(:read, Portal.Intune.Device, :api_client), do: :ok
  def permit(_action, Portal.Iru.PostureProvider, :account_admin_user), do: :ok
  def permit(:read, Portal.Iru.PostureProvider, :api_client), do: :ok
  def permit(:read, Portal.Iru.Device, :account_admin_user), do: :ok
  def permit(:read, Portal.Iru.Device, :api_client), do: :ok
  def permit(_action, Portal.Defender.PostureProvider, :account_admin_user), do: :ok
  def permit(:read, Portal.Defender.PostureProvider, :api_client), do: :ok
  def permit(:read, Portal.Defender.Device, :account_admin_user), do: :ok
  def permit(:read, Portal.Defender.Device, :api_client), do: :ok
  def permit(_action, Portal.Santa.PostureProvider, :account_admin_user), do: :ok
  def permit(:read, Portal.Santa.PostureProvider, :api_client), do: :ok
  def permit(:read, Portal.Santa.Device, :account_admin_user), do: :ok
  def permit(:read, Portal.Santa.Device, :api_client), do: :ok
  def permit(_action, Portal.SentinelOne.PostureProvider, :account_admin_user), do: :ok
  def permit(:read, Portal.SentinelOne.PostureProvider, :api_client), do: :ok
  def permit(:read, Portal.SentinelOne.Device, :account_admin_user), do: :ok
  def permit(:read, Portal.SentinelOne.Device, :api_client), do: :ok
  def permit(_action, Portal.Google.Directory, :account_admin_user), do: :ok
  def permit(:read, Portal.Google.Directory, :api_client), do: :ok
  def permit(_action, Portal.Okta.Directory, :account_admin_user), do: :ok
  def permit(:read, Portal.Okta.Directory, :api_client), do: :ok

  def permit(_action, Portal.LogSink, :account_admin_user), do: :ok
  def permit(_action, Portal.Splunk.LogSink, :account_admin_user), do: :ok
  def permit(_action, Portal.Datadog.LogSink, :account_admin_user), do: :ok
  def permit(_action, Portal.NewRelic.LogSink, :account_admin_user), do: :ok
  def permit(_action, Portal.Elastic.LogSink, :account_admin_user), do: :ok
  def permit(_action, Portal.Sentinel.LogSink, :account_admin_user), do: :ok
  def permit(_action, Portal.S3.LogSink, :account_admin_user), do: :ok
  def permit(_action, Portal.QRadar.LogSink, :account_admin_user), do: :ok
  def permit(_action, Portal.HTTP.LogSink, :account_admin_user), do: :ok
  def permit(:read, Portal.LogSinkCursor, :account_admin_user), do: :ok

  def permit(_action, Portal.PortalSession, :account_admin_user), do: :ok

  # Oban.Job permissions - admin only
  def permit(:read, Oban.Job, :account_admin_user), do: :ok

  # Device permissions (union of Client + Gateway); non-admin actors can
  # insert because clients create their own device row at first connect
  def permit(_action, Portal.Device, :account_admin_user), do: :ok
  def permit(_action, Portal.Device, :api_client), do: :ok
  def permit(:read, Portal.Device, :account_user), do: :ok
  def permit(:update, Portal.Device, :account_user), do: :ok
  def permit(:insert, Portal.Device, :account_user), do: :ok
  def permit(:read, Portal.Device, :service_account), do: :ok
  def permit(:update, Portal.Device, :service_account), do: :ok
  def permit(:insert, Portal.Device, :service_account), do: :ok

  # PolicyAuthorization permissions - all actor types can read and create policy_authorizations
  def permit(:read, Portal.PolicyAuthorization, _), do: :ok
  def permit(:insert, Portal.PolicyAuthorization, _), do: :ok
  # Only admin can delete policy_authorizations
  def permit(_action, Portal.PolicyAuthorization, :account_admin_user), do: :ok

  # Site permissions
  def permit(_action, Portal.Site, :account_admin_user), do: :ok
  def permit(_action, Portal.Site, :api_client), do: :ok
  def permit(:read, Portal.Site, _), do: :ok

  # GatewayToken permissions
  def permit(_action, Portal.GatewayToken, :account_admin_user), do: :ok
  def permit(_action, Portal.GatewayToken, :api_client), do: :ok

  # Resource permissions
  def permit(_action, Portal.Resource, :account_admin_user), do: :ok
  def permit(_action, Portal.Resource, :api_client), do: :ok
  def permit(:read, Portal.Resource, _), do: :ok

  # StaticDevicePoolMember permissions
  def permit(_action, Portal.StaticDevicePoolMember, :account_admin_user), do: :ok
  def permit(_action, Portal.StaticDevicePoolMember, :api_client), do: :ok
  def permit(:read, Portal.StaticDevicePoolMember, _), do: :ok

  # Policy permissions
  def permit(_action, Portal.Policy, :account_admin_user), do: :ok
  def permit(_action, Portal.Policy, :api_client), do: :ok
  def permit(:read, Portal.Policy, _), do: :ok

  # Membership permissions
  def permit(_action, Portal.Membership, :account_admin_user), do: :ok
  def permit(_action, Portal.Membership, :api_client), do: :ok
  def permit(:read, Portal.Membership, _), do: :ok

  # ChangeLog permissions
  def permit(:read, Portal.ChangeLog, :account_admin_user), do: :ok
  def permit(:read, Portal.ChangeLog, :api_client), do: :ok

  # TrustAnchor permissions
  def permit(_action, Portal.TrustAnchor, :account_admin_user), do: :ok
  def permit(:read, Portal.TrustAnchor, :api_client), do: :ok
  def permit(:read, Portal.TrustAnchorCertificate, _), do: :ok

  # Every attested connect checks the cached CRL for the anchor that issued its
  # certificate, so any actor type that can attest must be able to read it.
  def permit(:read, Portal.CrlRevocation, _), do: :ok

  # Readable by any actor type that can attest, since the connect path consults
  # it to tell an issuer that publishes a list from one that only answers a
  # responder. The rows are otherwise written by the connect that discovers them
  # and by the fetch jobs, both of which pin the account themselves.
  def permit(:read, Portal.RevocationEndpoint, _), do: :ok

  # An endpoint that keeps failing stops being fetched from, and saving the
  # trust anchor its issuer belongs to is the only way to start again.
  def permit(:update_all, Portal.RevocationEndpoint, :account_admin_user), do: :ok

  # Every attested connect checks the cached status of its own certificate when
  # its CA publishes no list, so any actor type that can attest must read it.
  def permit(:read, Portal.OcspStatus, _), do: :ok

  # SessionLog permissions
  def permit(:read, Portal.SessionLog, :account_admin_user), do: :ok
  def permit(:read, Portal.SessionLog, :api_client), do: :ok

  # FlowLog permissions
  def permit(:read, Portal.FlowLog, :account_admin_user), do: :ok
  def permit(:read, Portal.FlowLog, :api_client), do: :ok

  # APIRequestLog permissions
  def permit(:read, Portal.APIRequestLog, :account_admin_user), do: :ok
  def permit(:read, Portal.APIRequestLog, :api_client), do: :ok

  def permit(_action, _struct, _type), do: {:error, :unauthorized}

  # Helper function to emit subject information to the replication stream
  defp emit_subject_message(%Subject{} = subject) do
    message = subject |> Subject.to_map() |> JSON.encode!()
    Repo.query!("SELECT pg_logical_emit_message(true, 'subject', $1)", [message])
  end
end
