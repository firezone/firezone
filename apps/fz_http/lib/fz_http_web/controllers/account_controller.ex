defmodule FzHttpWeb.AccountController do
  @moduledoc """
  Handles account-related operations
  """
  use FzHttpWeb, :controller

  plug :redirect_unauthenticated
end
