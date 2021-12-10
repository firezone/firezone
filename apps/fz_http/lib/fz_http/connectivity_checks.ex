defmodule FzHttp.ConnectivityChecks do
  @moduledoc """
  The ConnectivityChecks context.
  """

  import Ecto.Query, warn: false
  alias FzHttp.Repo

  alias FzHttp.ConnectivityChecks.ConnectivityCheck

  @doc """
  Returns the list of connectivity_checks.

  ## Examples

      iex> list_connectivity_checks()
      [%ConnectivityCheck{}, ...]

  """
  def list_connectivity_checks do
    Repo.all(ConnectivityCheck)
  end

  def list_connectivity_checks(limit: limit) when is_integer(limit) do
    Repo.all(
      from(
        c in ConnectivityCheck,
        limit: ^limit,
        order_by: [desc: :inserted_at]
      )
    )
  end

  @doc """
  Gets a single connectivity_check.

  Raises `Ecto.NoResultsError` if the ConnectivityCheck does not exist.

  ## Examples

      iex> get_connectivity_check!(123)
      %ConnectivityCheck{}

      iex> get_connectivity_check!(456)
      ** (Ecto.NoResultsError)

  """
  def get_connectivity_check!(id), do: Repo.get!(ConnectivityCheck, id)

  @doc """
  Creates a connectivity_check.

  ## Examples

      iex> create_connectivity_check(%{field: value})
      {:ok, %ConnectivityCheck{}}

      iex> create_connectivity_check(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_connectivity_check(attrs \\ %{}) do
    %ConnectivityCheck{}
    |> ConnectivityCheck.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a connectivity_check.

  ## Examples

      iex> update_connectivity_check(connectivity_check, %{field: new_value})
      {:ok, %ConnectivityCheck{}}

      iex> update_connectivity_check(connectivity_check, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_connectivity_check(%ConnectivityCheck{} = connectivity_check, attrs) do
    connectivity_check
    |> ConnectivityCheck.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a connectivity_check.

  ## Examples

      iex> delete_connectivity_check(connectivity_check)
      {:ok, %ConnectivityCheck{}}

      iex> delete_connectivity_check(connectivity_check)
      {:error, %Ecto.Changeset{}}

  """
  def delete_connectivity_check(%ConnectivityCheck{} = connectivity_check) do
    Repo.delete(connectivity_check)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking connectivity_check changes.

  ## Examples

      iex> change_connectivity_check(connectivity_check)
      %Ecto.Changeset{data: %ConnectivityCheck{}}

  """
  def change_connectivity_check(%ConnectivityCheck{} = connectivity_check, attrs \\ %{}) do
    ConnectivityCheck.changeset(connectivity_check, attrs)
  end

  @doc """
  Returns the latest connectivity_check.
  """
  def latest_connectivity_check do
    Repo.one(
      from(
        c in ConnectivityCheck,
        limit: 1,
        order_by: [desc: :inserted_at]
      )
    )
  end

  @doc """
  Returns the latest connectivity_check's response_body which should contain the resolved public
  IP.
  """
  def endpoint do
    case latest_connectivity_check() do
      nil -> nil
      connectivity_check -> connectivity_check.response_body
    end
  end
end
