defmodule FzHttp.SessionsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `FzHttp.Sessions` context.
  """
  alias FzHttp.{Sessions, UsersFixtures}

  def session(_attrs \\ %{}) do
    email = UsersFixtures.user().email
    record = Sessions.get_session!(email: email)
    create_params = %{email: email, password: "password1234"}
    {:ok, session} = Sessions.create_session(record, create_params)
    session
  end
end
