defmodule API.GatewayTokenJSON do
  def show(%{token: token, encoded_token: encoded_token}) do
    %{
      data: %{
        id: token.id,
        token: encoded_token
      }
    }
  end

  def deleted(%{token: token}) do
    %{
      data: %{
        id: token.id
      }
    }
  end

  def deleted_all(%{count: count}) do
    %{
      data: %{
        deleted_count: count
      }
    }
  end
end
