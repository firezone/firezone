defmodule PortalAPI.FallbackController do
  use PortalAPI, :controller

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(json: PortalAPI.ErrorJSON)
    |> render(:"404")
  end

  def call(conn, {:error, :unauthorized}) do
    conn
    |> put_status(:unauthorized)
    |> put_view(json: PortalAPI.ErrorJSON)
    |> render(:"401")
  end

  def call(conn, {:error, {:unauthorized, details}}) do
    reason = Keyword.get(details, :reason, "Unauthorized")

    conn
    |> put_status(:unauthorized)
    |> put_view(json: PortalAPI.ErrorJSON)
    |> render(:"401", reason: reason)
  end

  def call(conn, {:error, :bad_request}) do
    conn
    |> put_status(:bad_request)
    |> put_view(json: PortalAPI.ErrorJSON)
    |> render(:"400")
  end

  def call(conn, {:error, :unprocessable_entity}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: PortalAPI.ErrorJSON)
    |> render(:"422")
  end

  def call(conn, {:error, :seats_limit_reached}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: PortalAPI.ErrorJSON)
    |> render(:error, reason: "Seat Limit Reached")
  end

  def call(conn, {:error, :service_accounts_limit_reached}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: PortalAPI.ErrorJSON)
    |> render(:error, reason: "Service Accounts Limit Reached")
  end

  def call(conn, {:error, :users_limit_reached}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: PortalAPI.ErrorJSON)
    |> render(:error, reason: "Users Limit Reached")
  end

  def call(conn, {:error, :admins_limit_reached}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: PortalAPI.ErrorJSON)
    |> render(:error, reason: "Admins Limit Reached")
  end

  def call(conn, {:error, :update_managed_group}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: PortalAPI.ErrorJSON)
    |> render(:error, reason: "Cannot update a managed group")
  end

  def call(conn, {:error, :update_synced_group}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: PortalAPI.ErrorJSON)
    |> render(:error, reason: "Cannot update a synced group")
  end

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: PortalAPI.ChangesetJSON)
    |> render(:error, status: 422, changeset: changeset)
  end

  def call(conn, {:error, :rollback}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: PortalAPI.ErrorJSON)
    |> render(:error, status: 422, reason: "Invalid payload")
  end

  def call(conn, {:error, :invalid_cursor}) do
    conn
    |> put_status(:bad_request)
    |> put_view(json: PortalAPI.ErrorJSON)
    |> render(:error, reason: "Invalid cursor")
  end
end
