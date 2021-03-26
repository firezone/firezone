defmodule FgHttp.SessionsTest do
  use FgHttp.DataCase, async: true

  alias FgHttp.Sessions

  describe "get_session!/1" do
    setup [:create_session]

    test "gets session by id", %{session: session} do
      assert session.id == Sessions.get_session!(session.id).id
    end

    test "gets session by email", %{session: session} do
      assert session.id == Sessions.get_session!(email: session.email).id
    end
  end

  describe "get_session/1" do
    setup [:create_session]

    test "gets session by id", %{session: session} do
      assert session.id == Sessions.get_session(session.id).id
    end

    test "gets session by email", %{session: session} do
      assert session.id == Sessions.get_session(email: session.email).id
    end
  end

  describe "new_session/0" do
    test "returns changeset" do
      assert %Ecto.Changeset{} = Sessions.new_session()
    end
  end

  describe "create_session/2" do
    setup [:create_user]

    @params %{password: "test"}

    test "creates session (updates existing record)", %{user: user} do
      session = Sessions.get_session!(email: user.email)
      assert is_nil(session.last_signed_in_at)

      {:ok, test_session} = Sessions.create_session(session, @params)
      assert !is_nil(test_session.last_signed_in_at)
    end
  end
end
