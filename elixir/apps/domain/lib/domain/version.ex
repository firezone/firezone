defmodule Domain.Version do
  def fetch_version(user_agent) when is_binary(user_agent) do
    user_agent
    |> URI.decode()
    |> String.split(" ")
    |> Enum.find_value(fn
      "relay/" <> version -> version
      "connlib/" <> version -> version
      _ -> nil
    end)
    |> case do
      nil -> {:error, :invalid_user_agent}
      version -> {:ok, version}
    end
  end

  def fetch_gateway_version(_user_agent) do
    {:error, :invalid_user_agent}
  end
end
