defmodule FzHttp.NetworkPolicies do
  @moduledoc """
  The NetworkPolicies context.
  """

  import Ecto.Query, warn: false
  alias FzHttp.Repo

  alias FzHttp.NetworkPolicies.NetworkPolicy

  @doc """
  Returns the list of network policies.

  ## Examples

      iex> list_network_policies()
      [%NetworkPolicy{}, ...]

  """
  def list_network_policies do
    Repo.all(NetworkPolicy)
  end

  @doc """
  Gets a single network policy.

  Raises `Ecto.NoResultsError` if the NetworkPolicy does not exist.

  ## Examples

      iex> get_network_policy!(123)
      %NetworkPolicy{}

      iex> get_network_policy!(456)
      ** (Ecto.NoResultsError)

  """
  def get_network_policy!(id), do: Repo.get!(NetworkPolicy, id)

  @doc """
  Creates a network policy.

  ## Examples

      iex> create_network_policy(%{field: value, ...})
      {:ok, %NetworkPolicy{field: value, ...}}

      iex> create_network_policy(%{field: bad_value, ...})
      {:error, %Ecto.Changeset{field: bad_value, ...}}

  """
  def create_network_policy(attrs \\ %{}) do
    %NetworkPolicy{}
    |> NetworkPolicy.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a network policy.

  ## Examples

      iex> update_network_policy(network_policy, %{field: new_value, ...})
      {:ok, %NetworkPolicy{field: new_value, ...}}

      iex> update_network_poolicy(network_policy, %{field: bad_value})
      {:error, %Ecto.Changeset{field: bad_value, ...}}

  """
  def update_network_policy(%NetworkPolicy{} = network_policy, attrs) do
    network_policy
    |> NetworkPolicy.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a network policy.

  ## Examples

      iex> delete_network_policy(network_policy)
      {:ok, %NetworkPolicy{}}

      iex> delete_network_policy(network_policy)
      {:error, %Ecto.Changeset{}}

  """
  def delete_network_policy(%NetworkPolicy{} = network_policy) do
    Repo.delete(network_policy)
  end
end
