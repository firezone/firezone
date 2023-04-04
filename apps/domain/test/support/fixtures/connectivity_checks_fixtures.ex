defmodule Domain.ConnectivityChecksFixtures do
  alias Domain.Repo
  alias Domain.ConnectivityChecks

  def connectivity_check_attrs(attrs \\ []) do
    Enum.into(attrs, %{
      response_body: "some response_body",
      response_code: 142,
      response_headers: %{"Content-Type" => "text/plain"},
      url: "https://ping-dev.firez.one/0.0.0+git.0.deadbeef0"
    })
  end

  def create_connectivity_check(attrs \\ []) do
    attrs
    |> connectivity_check_attrs()
    |> ConnectivityChecks.ConnectivityCheck.Changeset.create_changeset()
    |> Repo.insert!()
  end
end
