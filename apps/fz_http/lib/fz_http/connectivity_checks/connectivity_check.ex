defmodule FzHttp.ConnectivityChecks.ConnectivityCheck do
  @moduledoc """
  Manages the connectivity_checks table
  """
  use FzHttp, :schema
  import Ecto.Changeset

  @url_regex ~r<\Ahttps://ping(?:-dev)?\.firez\.one/\d+\.\d+\.\d+(?:\+git\.\d+\.[0-9a-fA-F]{7,})?\z>

  schema "connectivity_checks" do
    field :response_body, :string
    field :response_code, :integer
    field :response_headers, :map
    field :url, :string

    timestamps(updated_at: false)
  end

  @doc false
  def changeset(connectivity_check, attrs) do
    connectivity_check
    |> cast(attrs, [:url, :response_body, :response_code, :response_headers])
    |> validate_required([:url, :response_code])
    |> validate_format(:url, @url_regex)
    |> validate_number(:response_code, greater_than_or_equal_to: 100, less_than: 600)
  end
end
