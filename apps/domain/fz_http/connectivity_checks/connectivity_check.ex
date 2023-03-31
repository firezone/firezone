defmodule FzHttp.ConnectivityChecks.ConnectivityCheck do
  use FzHttp, :schema

  schema "connectivity_checks" do
    field :response_body, :string
    field :response_code, :integer
    field :response_headers, :map
    field :url, :string

    timestamps(updated_at: false)
  end
end
