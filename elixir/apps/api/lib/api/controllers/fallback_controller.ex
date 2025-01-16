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
    |> put_status(:unauthorized)
    |> put_view(json: API.ErrorJSON)
    |> render(:"401")
  end

  def call(conn, {:error, :bad_request}) do
    conn
    |> put_status(:bad_request)
    |> put_view(json: API.ErrorJSON)
    |> render(:"400")
  end

  def call(conn, {:error, :unprocessable_entity}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: API.ErrorJSON)
    |> render(:"422")
  end

  def call(conn, {:error, :seats_limit_reached}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: API.ErrorJSON)
    |> render(:error, reason: "Seat Limit Reached")
  end

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: API.ChangesetJSON)
    |> render(:error, status: 422, changeset: changeset)
  end
end
