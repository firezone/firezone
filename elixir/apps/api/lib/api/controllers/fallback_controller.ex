defmodule API.FallbackController do
  use Phoenix.Controller

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(json: API.ErrorJSON)
    |> render(:"404")
  end

  def call(conn, {:error, :unauthorized}) do
    conn
    |> put_status(403)
    |> put_view(json: API.ErrorJSON)
    |> render(:"403")
  end

  def call(conn, {:error, :bad_request}) do
    conn
    |> put_status(400)
    |> put_view(json: API.ErrorJSON)
    |> render(:"400")
  end

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: API.ChangesetJSON)
    |> render(:error, changeset: changeset)
  end
end
