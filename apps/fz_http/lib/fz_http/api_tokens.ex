defmodule FzHttp.ApiTokens do
  @moduledoc """
  The ApiTokens context.
  """

  import Ecto.Query, warn: false
  alias FzHttp.Repo

  alias FzHttp.ApiTokens.ApiToken

  @doc """
  Returns the list of api_tokens.

  ## Examples

      iex> list_api_tokens()
      [%ApiToken{}, ...]

  """
  def list_api_tokens do
    Repo.all(ApiToken)
  end

  @doc """
  Gets a single api_token.

  Raises `Ecto.NoResultsError` if the Api token does not exist.

  ## Examples

      iex> get_api_token!(123)
      %ApiToken{}

      iex> get_api_token!(456)
      ** (Ecto.NoResultsError)

  """
  def get_api_token!(id), do: Repo.get!(ApiToken, id)

  @doc """
  Creates a api_token.

  ## Examples

      iex> create_api_token(%{field: value})
      {:ok, %ApiToken{}}

      iex> create_api_token(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_api_token(attrs \\ %{}) do
    %ApiToken{}
    |> ApiToken.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a api_token.

  ## Examples

      iex> update_api_token(api_token, %{field: new_value})
      {:ok, %ApiToken{}}

      iex> update_api_token(api_token, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_api_token(%ApiToken{} = api_token, attrs) do
    api_token
    |> ApiToken.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a api_token.

  ## Examples

      iex> delete_api_token(api_token)
      {:ok, %ApiToken{}}

      iex> delete_api_token(api_token)
      {:error, %Ecto.Changeset{}}

  """
  def delete_api_token(%ApiToken{} = api_token) do
    Repo.delete(api_token)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking api_token changes.

  ## Examples

      iex> change_api_token(api_token)
      %Ecto.Changeset{data: %ApiToken{}}

  """
  def change_api_token(%ApiToken{} = api_token, attrs \\ %{}) do
    ApiToken.changeset(api_token, attrs)
  end
end
