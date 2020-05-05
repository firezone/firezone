defmodule CfHttp.FirewallRules do
  @moduledoc """
  The FirewallRules context.
  """

  import Ecto.Query, warn: false
  alias CfHttp.Repo

  alias CfHttp.FirewallRules.FirewallRule

  @doc """
  Returns the list of firewall_rules.

  ## Examples

      iex> list_firewall_rules()
      [%FirewallRule{}, ...]

  """
  def list_firewall_rules do
    Repo.all(FirewallRule)
  end

  @doc """
  Gets a single firewall_rule.

  Raises `Ecto.NoResultsError` if the Firewall rule does not exist.

  ## Examples

      iex> get_firewall_rule!(123)
      %FirewallRule{}

      iex> get_firewall_rule!(456)
      ** (Ecto.NoResultsError)

  """
  def get_firewall_rule!(id), do: Repo.get!(FirewallRule, id)

  @doc """
  Creates a firewall_rule.

  ## Examples

      iex> create_firewall_rule(%{field: value})
      {:ok, %FirewallRule{}}

      iex> create_firewall_rule(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_firewall_rule(attrs \\ %{}) do
    %FirewallRule{}
    |> FirewallRule.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a firewall_rule.

  ## Examples

      iex> update_firewall_rule(firewall_rule, %{field: new_value})
      {:ok, %FirewallRule{}}

      iex> update_firewall_rule(firewall_rule, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_firewall_rule(%FirewallRule{} = firewall_rule, attrs) do
    firewall_rule
    |> FirewallRule.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a firewall_rule.

  ## Examples

      iex> delete_firewall_rule(firewall_rule)
      {:ok, %FirewallRule{}}

      iex> delete_firewall_rule(firewall_rule)
      {:error, %Ecto.Changeset{}}

  """
  def delete_firewall_rule(%FirewallRule{} = firewall_rule) do
    Repo.delete(firewall_rule)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking firewall_rule changes.

  ## Examples

      iex> change_firewall_rule(firewall_rule)
      %Ecto.Changeset{source: %FirewallRule{}}

  """
  def change_firewall_rule(%FirewallRule{} = firewall_rule) do
    FirewallRule.changeset(firewall_rule, %{})
  end
end
