defmodule Portal.OSRelease do
  @moduledoc """
  The newest release of one operating system line and whether the vendor still
  supports it, as last fetched from the vendor's release feed.

  A line is what a device stays on between feature updates: a macOS, iOS or
  Android major version, a Windows build such as `10.0.26100`, or a Linux
  kernel series such as `6.12`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @timestamps_opts [type: :utc_datetime_usec]

  @type os :: :windows | :macos | :ios | :android | :linux
  @type t :: %__MODULE__{
          os: os(),
          line: String.t(),
          latest_version: String.t(),
          supported: boolean(),
          fetched_at: DateTime.t()
        }

  schema "os_releases" do
    field :os, Ecto.Enum, values: ~w[windows macos ios android linux]a, primary_key: true
    field :line, :string, primary_key: true
    field :latest_version, :string
    field :supported, :boolean
    field :fetched_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(release, attrs) do
    release
    |> cast(attrs, ~w[os line latest_version supported fetched_at]a)
    |> changeset()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    validate_required(changeset, ~w[os line latest_version supported fetched_at]a)
  end
end
