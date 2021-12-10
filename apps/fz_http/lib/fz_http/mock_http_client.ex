defmodule FzHttp.MockHttpClient do
  @moduledoc """
  Mocks http requests in place of HTTPoison
  """

  @success_response {
    :ok,
    %{
      headers: [
        {"content-length", 9},
        {"date", "Tue, 07 Dec 2021 19:57:02 GMT"}
      ],
      status_code: 200,
      body: "127.0.0.1"
    }
  }
  @error_sentinel "invalid-url"
  @error_response {:error, %{reason: :nxdomain}}

  def start, do: nil

  @doc """
  Simulates a POST. Include @error_sentinel in the request URL to simulate an error.
  """
  def post(url, _body) do
    if String.contains?(url, @error_sentinel) do
      @error_response
    else
      @success_response
    end
  end
end
