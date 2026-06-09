defmodule PortalAPI.ErrorTest do
  use PortalAPI.ConnCase, async: true

  import ExUnit.CaptureLog

  describe "handle/2" do
    test "renders 404 for {:error, :not_found}", %{conn: conn} do
      conn =
        conn
        |> put_format()
        |> PortalAPI.Error.handle({:error, :not_found})

      assert json_response(conn, 404) == %{
               "type" => "about:blank",
               "title" => "Not Found",
               "status" => 404,
               "detail" => "The requested resource could not be found."
             }
    end

    test "renders 401 for {:error, :unauthorized}", %{conn: conn} do
      conn =
        conn
        |> put_format()
        |> PortalAPI.Error.handle({:error, :unauthorized})

      assert json_response(conn, 401) == %{
               "type" => "about:blank",
               "title" => "Unauthorized",
               "status" => 401,
               "detail" => "Authentication credentials were missing or invalid."
             }
    end

    test "renders 400 for {:error, :bad_request}", %{conn: conn} do
      conn =
        conn
        |> put_format()
        |> PortalAPI.Error.handle({:error, :bad_request})

      assert json_response(conn, 400) == %{
               "type" => "about:blank",
               "title" => "Bad Request",
               "status" => 400,
               "detail" => "The request could not be processed."
             }
    end

    test "renders 400 with reason for {:error, :bad_request, reason: reason}", %{conn: conn} do
      conn =
        conn
        |> put_format()
        |> PortalAPI.Error.handle({:error, :bad_request, reason: "invalid thing"})

      assert json_response(conn, 400) == %{
               "type" => "about:blank",
               "title" => "Bad Request",
               "status" => 400,
               "detail" => "invalid thing"
             }
    end

    test "renders 400 for {:error, :invalid_cursor}", %{conn: conn} do
      conn =
        conn
        |> put_format()
        |> PortalAPI.Error.handle({:error, :invalid_cursor})

      assert json_response(conn, 400) == %{
               "type" => "about:blank",
               "title" => "Bad Request",
               "status" => 400,
               "detail" => "Invalid page cursor"
             }
    end

    test "renders 403 for {:error, :forbidden}", %{conn: conn} do
      conn =
        conn
        |> put_format()
        |> PortalAPI.Error.handle({:error, :forbidden})

      assert json_response(conn, 403) == %{
               "type" => "about:blank",
               "title" => "Forbidden",
               "status" => 403,
               "detail" => "You do not have permission to perform this action."
             }
    end

    test "renders 403 with reason for {:error, :forbidden, reason: reason}", %{conn: conn} do
      conn =
        conn
        |> put_format()
        |> PortalAPI.Error.handle({:error, :forbidden, reason: "no access"})

      assert json_response(conn, 403) == %{
               "type" => "about:blank",
               "title" => "Forbidden",
               "status" => 403,
               "detail" => "no access"
             }
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
               "type" => "about:blank",
               "title" => "Unprocessable Content",
               "status" => 422,
               "detail" => "The request body failed validation.",
               "validation_errors" => %{"name" => ["is invalid"]}
             }
    end

    test "renders 500 for an unexpected error and logs it", %{conn: conn} do
      {conn, log} =
        with_log(fn ->
          conn
          |> put_format()
          |> PortalAPI.Error.handle({:error, :something_unexpected})
        end)

      assert json_response(conn, 500) == %{
               "type" => "about:blank",
               "title" => "Internal Server Error",
               "status" => 500,
               "detail" => "An unexpected error occurred."
             }

      assert log =~ "Unhandled API error"
    end
  end

  defp put_format(conn) do
    Phoenix.Controller.put_format(conn, "json")
  end
end
