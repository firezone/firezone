defmodule Portal.Devices do
  @moduledoc """
  Domain functions for provisioning devices, shared between the admin
  LiveView (`PortalWeb.Live.Sites`) and the REST API
  (`PortalAPI.GatewayController`) so there's one source of truth for the
  "insert a gateway and mint its single-owner token" flow.
  """

  alias Portal.Authentication
  alias Portal.Device
  alias Portal.ClientToken
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
  their own row on first connect) but not a ClientToken - so without the
  transaction a caller who can do the first and not the second gets a 401
  back while a tokenless Gateway stays behind in their account. The same
  applies to any other failure of the token insert, not just an
  authorization one.
  """
  @spec provision_gateway(Site.t(), String.t() | nil, Authentication.Subject.t()) ::
          {:ok, Device.t(), ClientToken.t(), binary()} | {:error, term()}
  def provision_gateway(%Site{} = site, name, %Authentication.Subject{} = subject) do
    provision_device(site, nil, name, subject)
  end

  @doc """
  Inserts a device that serves the given sites and mints the token it
  connects with, owned by `actor`: a service account of the account, or its
  Infrastructure service account when nil. The first site is the device's
  home site; the rest are assignments. A device may serve no site at all and
  be assigned later. See `provision_gateway/3` for why the writes share one
  transaction.
  """
  @spec provision_device(
          Site.t() | [Site.t()],
          Portal.Actor.t() | nil,
          String.t() | nil,
          Authentication.Subject.t()
        ) ::
          {:ok, Device.t(), ClientToken.t(), binary()} | {:error, term()}
  def provision_device(%Site{} = site, actor, name, subject) do
    provision_device([site], actor, name, subject)
  end

  def provision_device(sites, actor, name, %Authentication.Subject{} = subject)
      when is_list(sites) do
    {home, extra} = List.pop_at(sites, 0)

    Database.transact(fn ->
      with {:ok, gateway} <- Database.insert_gateway(home, name, subject),
           :ok <- assign_extra_sites(gateway, extra, subject),
           {:ok, token} <- Authentication.create_device_token(gateway, actor, subject) do
        {:ok, {gateway, %{token | secret_fragment: nil}, Authentication.encode_fragment!(token)}}
      end
    end)
    |> case do
      {:ok, {gateway, token, encoded_fragment}} -> {:ok, gateway, token, encoded_fragment}
      {:error, reason} -> {:error, reason}
    end
  end

  # The home site's assignment is written by the mirror trigger; the rest
  # are written here.
  defp assign_extra_sites(gateway, sites, subject) do
    Enum.reduce_while(sites, :ok, fn site, :ok ->
      case Database.insert_site_device(site, gateway, subject) do
        {:ok, _site_device} -> {:cont, :ok}
        {:error, :already_assigned} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc "The account's service accounts a new device may connect as, Infrastructure first."
  @spec list_service_accounts(Authentication.Subject.t()) :: [Portal.Actor.t()]
  def list_service_accounts(%Authentication.Subject{} = subject),
    do: Database.list_service_accounts(subject)

  @doc "The account's own sites a new device may serve."
  @spec list_sites(Authentication.Subject.t()) :: [Site.t()]
  def list_sites(%Authentication.Subject{} = subject), do: Database.list_sites(subject)

  @doc "The sites with these ids, in the order given; unknown ids are dropped."
  @spec fetch_sites([Ecto.UUID.t()], Authentication.Subject.t()) :: [Site.t()]
  def fetch_sites(ids, %Authentication.Subject{} = subject) when is_list(ids),
    do: Database.fetch_sites(ids, subject)

  @doc """
  Assigns a device to a site so it serves the site's resources. Any device
  can be assigned; whether it is picked to serve depends on what it reports
  it can do when it connects.
  """
  @spec assign_to_site(Site.t(), Ecto.UUID.t(), Authentication.Subject.t()) ::
          {:ok, Portal.SiteDevice.t()}
          | {:error, :not_found | :already_assigned | :unauthorized}
  def assign_to_site(%Site{} = site, device_id, %Authentication.Subject{} = subject) do
    with {:ok, device} <- Database.fetch_device(device_id, subject) do
      Database.insert_site_device(site, device, subject)
    end
  end

  @doc """
  Takes a device off a site. A gateway's site column still has to name one
  of its sites: when that is the site being removed, the column moves to
  another assignment, and a gateway with no other site stays put with
  `:last_site`.
  """
  @spec unassign_from_site(Site.t(), Ecto.UUID.t(), Authentication.Subject.t()) ::
          {:ok, Device.t()} | {:error, :not_found | :last_site | :unauthorized}
  def unassign_from_site(%Site{} = site, device_id, %Authentication.Subject{} = subject) do
    with {:ok, device} <- Database.fetch_device(device_id, subject),
         other_site_ids = Database.other_site_ids(site, device, subject),
         {:ok, device} <- do_unassign(site, device, other_site_ids, subject) do
      {:ok, device}
    end
  end

  defp do_unassign(site, %Device{site_id: home_site_id} = device, _other_site_ids, subject)
       when home_site_id != site.id do
    with :ok <- Database.delete_site_device(site, device, subject), do: {:ok, device}
  end

  defp do_unassign(_site, _device, [], _subject), do: {:error, :last_site}

  # The mirror trigger removes the old assignment with the move.
  defp do_unassign(_site, device, [site_id | _], subject) do
    Database.move_home_site(device, site_id, subject)
  end

  @doc """
  Whether assigning the device to the site would have it serve the Internet
  resource alongside other resources: the site is the Internet Site and the
  device already serves another site, or the other way round.
  """
  @spec cohosts_internet?(Site.t(), Ecto.UUID.t(), Authentication.Subject.t()) :: boolean()
  def cohosts_internet?(%Site{} = site, device_id, %Authentication.Subject{} = subject) do
    Database.cohosts_internet?(site, device_id, subject)
  end

  defmodule Database do
    import Ecto.Query
    import Ecto.Changeset
    alias Portal.Safe
    alias Portal.{Device, Site, SiteDevice}

    def fetch_device(device_id, subject) do
      from(d in Device, as: :devices)
      |> where([devices: d], d.id == ^device_id)
      |> Safe.scoped(subject)
      |> Safe.one()
      |> case do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        device -> {:ok, device}
      end
    end

    def insert_site_device(site, device, subject) do
      %SiteDevice{}
      |> cast(%{account_id: site.account_id, site_id: site.id, device_id: device.id}, [
        :account_id,
        :site_id,
        :device_id
      ])
      |> SiteDevice.changeset()
      |> Safe.scoped(subject)
      |> Safe.insert()
      |> case do
        {:ok, site_device} -> {:ok, site_device}
        {:error, %Ecto.Changeset{errors: [account_id: _]}} -> {:error, :already_assigned}
        {:error, _reason} = error -> error
      end
    end

    def other_site_ids(site, device, subject) do
      from(sd in SiteDevice, as: :site_devices)
      |> where([site_devices: sd], sd.device_id == ^device.id and sd.site_id != ^site.id)
      |> select([site_devices: sd], sd.site_id)
      |> Safe.scoped(subject)
      |> Safe.all()
      |> case do
        {:error, :unauthorized} -> []
        site_ids -> site_ids
      end
    end

    def delete_site_device(site, device, subject) do
      from(sd in SiteDevice, as: :site_devices)
      |> where([site_devices: sd], sd.site_id == ^site.id and sd.device_id == ^device.id)
      |> Safe.scoped(subject)
      |> Safe.delete_all()
      |> case do
        {count, _} when count > 0 -> :ok
        {0, _} -> {:error, :not_found}
        {:error, _reason} = error -> error
      end
    end

    def move_home_site(device, site_id, subject) do
      device
      |> change(site_id: site_id)
      |> Safe.scoped(subject)
      |> Safe.update()
    end

    def cohosts_internet?(%Site{} = site, device_id, subject) do
      from(sd in SiteDevice, as: :site_devices)
      |> join(:inner, [site_devices: sd], s in Site,
        on: s.account_id == sd.account_id and s.id == sd.site_id,
        as: :sites
      )
      |> where([site_devices: sd], sd.device_id == ^device_id and sd.site_id != ^site.id)
      |> where_other_side_of_internet(site)
      |> Safe.scoped(subject)
      |> Safe.exists?()
    end

    defp where_other_side_of_internet(queryable, %Site{managed_by: :system}), do: queryable

    defp where_other_side_of_internet(queryable, %Site{}) do
      where(queryable, [sites: s], s.managed_by == :system)
    end

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
      |> Ecto.Changeset.put_change(:site_id, site && site.id)
      |> put_free_slug(subject.account.id, nil)
      |> Safe.scoped(subject)
      |> Safe.insert()
    end

    @doc "The account's service accounts, the Infrastructure one first."
    def list_service_accounts(subject) do
      from(a in Portal.Actor, as: :actors)
      |> where([actors: a], a.type == :service_account and a.is_disabled == false)
      |> order_by([actors: a],
        asc: fragment("CASE WHEN ? = 'system' THEN 0 ELSE 1 END", a.managed_by),
        asc: a.name
      )
      |> Safe.scoped(subject)
      |> Safe.all()
      |> case do
        {:error, _} -> []
        actors -> actors
      end
    end

    def list_sites(subject) do
      from(s in Site, as: :sites)
      |> where([sites: s], s.managed_by == :account)
      |> order_by([sites: s], asc: s.name)
      |> Safe.scoped(subject)
      |> Safe.all()
      |> case do
        {:error, _} -> []
        sites -> sites
      end
    end

    def fetch_sites(ids, subject) do
      from(s in Site, as: :sites)
      |> where([sites: s], s.id in ^ids)
      |> Safe.scoped(subject)
      |> Safe.all()
      |> case do
        {:error, _} -> []
        sites -> Enum.sort_by(sites, &Enum.find_index(ids, fn id -> id == &1.id end))
      end
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
