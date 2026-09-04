defmodule Portal.Features do
  # credo:disable-for-this-file Credo.Check.Warning.MissingChangesetFunction
  use Ecto.Schema

  @features [:trust_anchors, :device_posture, :mcp, :mcp_identity_management, :mcp_credential_issuance]
  @type feature :: :trust_anchors | :device_posture | :mcp | :mcp_identity_management | :mcp_credential_issuance

  @primary_key false

  schema "features" do
    field :feature, Ecto.Enum, values: @features
    field :enabled, :boolean, default: false
  end

  @spec enabled?(feature()) :: boolean()
  def enabled?(feature) when feature in @features, do: __MODULE__.Database.enabled?(feature)

  defmodule Database do
    import Ecto.Query

    alias Portal.Safe

    def enabled?(feature) do
      from(f in Portal.Features, where: f.feature == ^feature and f.enabled == true)
      |> Safe.unscoped()
      |> Safe.exists?()
    end
  end
end
