defmodule Portal.Devices do
  @moduledoc """
  Domain functions for provisioning devices, shared between the admin
  LiveView (`PortalWeb.Live.Sites`) and the REST API
  (`PortalAPI.GatewayController`) so there's one source of truth for the
  "insert a gateway and mint its single-owner token" flow.
  """

  alias Portal.Authentication
  alias Portal.Device
  alias Portal.GatewayToken
  alias Portal.Site
  alias __MODULE__.Database

  @doc "Puts the slug a device named in `changeset` gets in `account_id`, see `next_free_slug/3`."
  @spec put_free_slug(Ecto.Changeset.t(), Ecto.UUID.t(), String.t() | nil) :: Ecto.Changeset.t()
  defdelegate put_free_slug(changeset, account_id, owner_name), to: Database

  @doc """
  The slug a device named `name` gets in `account_id`, composed by the `device_slug`
  database function: the name's first dotted part, lowercased, with `owner_name`'s
  first name in front unless the name already carries it, then numbered when
  another device in the account holds it.
  """
  @spec next_free_slug(Ecto.UUID.t(), String.t(), String.t() | nil) :: String.t()
  defdelegate next_free_slug(account_id, name, owner_name), to: Database

  @doc "The name that prefixes a device slug: the owner's for people, nothing for service accounts."
  @spec owner_name(Portal.Actor.t() | nil) :: String.t() | nil
  def owner_name(%Portal.Actor{type: type, name: name})
      when type in [:account_user, :account_admin_user],
      do: name

  def owner_name(_actor), do: nil

  @doc """
  Inserts a Gateway and mints its single-owner token.

  Both writes happen in one transaction. They are separately authorized -
  `Safe.permit/3` lets an `account_user` insert a Device (clients create
  their own row on first connect) but not a GatewayToken - so without the
  transaction a caller who can do the first and not the second gets a 401
  back while a tokenless Gateway stays behind in their account. The same
  applies to any other failure of the token insert, not just an
  authorization one.
  """
  @spec provision_gateway(Site.t(), String.t() | nil, Authentication.Subject.t()) ::
          {:ok, Device.t(), GatewayToken.t(), binary()} | {:error, term()}
  def provision_gateway(%Site{} = site, name, %Authentication.Subject{} = subject) do
    Database.transact(fn ->
      with {:ok, gateway} <- Database.insert_gateway(site, name, subject),
           {:ok, token} <- Authentication.create_gateway_token(gateway, subject) do
        {:ok, {gateway, %{token | secret_fragment: nil}, Authentication.encode_fragment!(token)}}
      end
    end)
    |> case do
      {:ok, {gateway, token, encoded_fragment}} -> {:ok, gateway, token, encoded_fragment}
      {:error, reason} -> {:error, reason}
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    # Repo.transact/1 rolls the transaction back when fun returns
    # {:error, _}, which is what makes provision_gateway/3 all-or-nothing.
    def transact(fun), do: Safe.transact(fun)

    # Builds a changeset rather than a bare struct on purpose: Safe.insert/1
    # only applies the schema's own changeset/1 to changesets, not to structs
    # (see its two Scoped clauses). Inserting a struct here would skip
    # Device.changeset/1 entirely and persist names it rejects - blank,
    # whitespace-only, or longer than 255 - instead of returning the 422 the
    # provisioning endpoint documents.
    #
    # Only a nil name gets a generated one. An explicitly supplied blank
    # string is invalid input, not an omitted value, so it is validated and
    # refused rather than silently replaced.
    def insert_gateway(site, name, subject) do
      name = name || Portal.Crypto.random_token(5, encoder: :user_friendly)

      %Device{}
      |> Ecto.Changeset.cast(%{name: name}, [:name])
      |> Ecto.Changeset.put_change(:type, :gateway)
      |> Ecto.Changeset.put_change(:site_id, site.id)
      |> put_free_slug(subject.account.id, nil)
      |> Safe.scoped(subject)
      |> Safe.insert()
    end

    def put_free_slug(changeset, account_id, owner_name) do
      case Ecto.Changeset.get_field(changeset, :name) do
        nil -> changeset
        name -> Ecto.Changeset.put_change(changeset, :slug, next_free_slug(account_id, name, owner_name))
      end
    end

    # Two devices inserted at the same time can still race for the slug; callers that
    # must not fail retry on the unique violation.
    def next_free_slug(account_id, name, owner_name) do
      from(
        slug in fragment(
          "SELECT next_free_device_slug(?, ?, ?) AS slug",
          type(^account_id, :binary_id),
          ^name,
          ^owner_name
        ),
        select: %{slug: slug.slug}
      )
      |> Safe.unscoped()
      |> Safe.one()
      |> Map.fetch!(:slug)
    end
  end
end
