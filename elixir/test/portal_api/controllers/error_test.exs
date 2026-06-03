defmodule PortalAPI.ErrorTest do
  use PortalAPI.ConnCase, async: true

  import ExUnit.CaptureLog

  describe "handle/2" do
    test "renders 404 for {:error, :not_found}", %{conn: conn} do
      conn =
        conn
        |> put_format()
        |> PortalAPI.Error.handle({:error, :not_found})

      assert json_response(conn, 404) == %{"error" => %{"reason" => "Not Found"}}
    end

    test "renders 401 for {:error, :unauthorized}", %{conn: conn} do
      conn =
        conn
        |> put_format()
        |> PortalAPI.Error.handle({:error, :unauthorized})

      assert json_response(conn, 401) == %{"error" => %{"reason" => "Unauthorized"}}
    end

    test "renders 400 for {:error, :bad_request}", %{conn: conn} do
      conn =
        conn
        |> put_format()
        |> PortalAPI.Error.handle({:error, :bad_request})

      assert json_response(conn, 400) == %{"error" => %{"reason" => "Bad Request"}}
    end

    test "renders 400 with reason for {:error, :bad_request, reason: reason}", %{conn: conn} do
      conn =
        conn
        |> put_format()
        |> PortalAPI.Error.handle({:error, :bad_request, reason: "invalid thing"})

      assert json_response(conn, 400) == %{"error" => %{"reason" => "invalid thing"}}
    end

    test "renders 400 for {:error, :invalid_cursor}", %{conn: conn} do
      conn =
        conn
        |> put_format()
        |> PortalAPI.Error.handle({:error, :invalid_cursor})

      assert json_response(conn, 400) == %{"error" => %{"reason" => "Invalid page cursor"}}
    end

    test "renders 403 for {:error, :forbidden}", %{conn: conn} do
      conn =
        conn
        |> put_format()
        |> PortalAPI.Error.handle({:error, :forbidden})

      assert json_response(conn, 403) == %{"error" => %{"reason" => "Forbidden"}}
    end

    test "renders 403 with reason for {:error, :forbidden, reason: reason}", %{conn: conn} do
      conn =
        conn
        |> put_format()
        |> PortalAPI.Error.handle({:error, :forbidden, reason: "no access"})

      assert json_response(conn, 403) == %{"error" => %{"reason" => "no access"}}
    end

    test "renders 422 for {:error, %Ecto.Changeset{}}", %{conn: conn} do
      changeset =
        %Portal.Account{}
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.add_error(:name, "is invalid")

      conn =
        conn
        |> put_format()
        |> PortalAPI.Error.handle({:error, changeset})

      assert json_response(conn, 422) == %{
               "error" => %{
                 "reason" => "Unprocessable Content",
                 "validation_errors" => %{"name" => ["is invalid"]}
               }
             }
    end

    test "renders 500 for an unexpected error and logs it", %{conn: conn} do
      {conn, log} =
        with_log(fn ->
          conn
          |> put_format()
          |> PortalAPI.Error.handle({:error, :something_unexpected})
        end)

      assert json_response(conn, 500) == %{"error" => %{"reason" => "Internal Server Error"}}
      assert log =~ "Unhandled API error"
    end
  end

  defp put_format(conn) do
    Phoenix.Controller.put_format(conn, "json")
  end
end
