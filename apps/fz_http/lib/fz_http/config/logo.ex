defmodule FzHttp.Config.Logo do
  @moduledoc """
  Embedded Schema for logo
  """
  use FzHttp, :schema
  import FzHttp.Validator
  import Ecto.Changeset

  @whitelisted_file_extensions ~w[.jpg .jpeg .png .gif .webp .avif .svg .tiff]

  # Singleton per configuration
  @primary_key false
  embedded_schema do
    field :url, :string
    field :file, :string
    field :data, :string
    field :type, :string
  end

  def __types__, do: ~w[Default File URL Upload]

  def type(nil), do: "Default"
  def type(%{file: path}) when not is_nil(path), do: "File"
  def type(%{url: url}) when not is_nil(url), do: "URL"
  def type(%{data: data}) when not is_nil(data), do: "Upload"

  def changeset(logo \\ %__MODULE__{}, attrs) do
    logo
    |> cast(attrs, [:url, :data, :file, :type])
    |> validate_file(:file, extensions: @whitelisted_file_extensions)
    |> move_file_to_static
  end

  defp move_file_to_static(changeset) do
    case fetch_change(changeset, :file) do
      {:ok, file} ->
        directory = Path.join(Application.app_dir(:fz_http), "priv/static/uploads/logo")
        file_name = Path.basename(file)
        file_path = Path.join(directory, file_name)
        File.mkdir_p!(directory)
        File.cp!(file, file_path)
        put_change(changeset, :file, file_name)

      :error ->
        changeset
    end
  end
end
