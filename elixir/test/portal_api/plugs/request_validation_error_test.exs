defmodule PortalAPI.Plugs.RequestValidationErrorTest do
  use ExUnit.Case, async: true

  alias OpenApiSpex.Cast.Error
  alias PortalAPI.Plugs.RequestValidationError

  test "overlapping field and child errors return 422 in either order" do
    parent = [:resource, :device_membership_criteria, "x-schemathesis-additional", :value]

    for child <- [:subject, 0], reverse? <- [false, true] do
      errors = [
        %Error{path: parent, reason: :invalid_type},
        %Error{path: parent, reason: :null_value},
        %Error{path: parent ++ [child], reason: :invalid_type},
        %Error{path: [:resource, :name], reason: :missing_field}
      ]

      errors = if reverse?, do: Enum.reverse(errors), else: errors
      conn = RequestValidationError.call(Plug.Test.conn(:post, "/resources"), errors)

      assert conn.status == 422
      assert conn.halted

      assert Plug.Conn.get_resp_header(conn, "content-type") == [
               "application/problem+json; charset=utf-8"
             ]

      validation_errors = Jason.decode!(conn.resp_body)["validation_errors"]
      assert validation_errors["name"] == ["can't be blank"]

      assert Enum.sort(
               validation_errors["device_membership_criteria"]["x-schemathesis-additional"][
                 "value"
               ]
             ) ==
               ["can't be blank", "is invalid"]
    end
  end

  test "preserves nested errors and multiple messages at the same leaf" do
    errors = [
      %Error{path: [:resource, :filters, 0, :ports], reason: :invalid_type},
      %Error{path: [:resource, :filters, 0, :ports], reason: :null_value},
      %Error{path: [:resource, :filters, 1, :protocol], reason: :invalid_enum}
    ]

    conn = RequestValidationError.call(Plug.Test.conn(:post, "/resources"), errors)

    assert conn.status == 422

    assert Jason.decode!(conn.resp_body)["validation_errors"] == %{
             "filters" => %{
               "0" => %{"ports" => ["can't be blank", "is invalid"]},
               "1" => %{"protocol" => ["is invalid"]}
             }
           }
  end
end
