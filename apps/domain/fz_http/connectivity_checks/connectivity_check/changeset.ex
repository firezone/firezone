defmodule FzHttp.ConnectivityChecks.ConnectivityCheck.Changeset do
  use FzHttp, :changeset
  alias FzHttp.ConnectivityChecks.ConnectivityCheck

  def create_changeset(attrs) do
    %ConnectivityCheck{}
    |> cast(attrs, [:url, :response_body, :response_code, :response_headers])
    |> validate_required([:url, :response_code])
    |> validate_number(:response_code, greater_than_or_equal_to: 100, less_than: 600)
  end
end
