defmodule API.Session do
  def options do
    [
      store: :cookie,
      key: "_firezone_api_key",
      same_site: "Lax",
      # 4 hours
      max_age: 14_400,
      sign: true,
      encrypt: true,
      secure: cookie_secure(),
      signing_salt: signing_salt(),
      encryption_salt: encryption_salt()
    ]
  end

  defp cookie_secure do
    Domain.Config.fetch_env!(:api, :cookie_secure)
  end

  defp signing_salt do
    [vsn | _] =
      Application.spec(:domain, :vsn)
      |> to_string()
      |> String.split("+")

    Domain.Config.fetch_env!(:api, :cookie_signing_salt) <> vsn
  end

  defp encryption_salt do
    Domain.Config.fetch_env!(:api, :cookie_encryption_salt)
  end
end
