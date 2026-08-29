defmodule Portal.Scope do
  @moduledoc """
  The scopes a credential may carry, shared by every credential type that
  supports them.

  A scope names an **entity** of the public API and an access level, written
  `entity:read` or `entity:write`. Entities are named after the API surface
  rather than the schemas behind it, because that is what the holder of a
  credential reasons about: `/clients` is `clients`, even though it is backed
  by `Portal.Device`.

  Each entity declares only the levels its routes actually need, so the list
  never offers a grant that nothing would ever check. `account` is read only
  because `GET /account` is all the API exposes, and `gateway_tokens` is write
  only because a gateway token can be minted, rotated and deleted but never
  read back.

  `write` implies `read` wherever an entity has both: a broader scope has to
  satisfy a check for a narrower one, so write is always stored alongside read
  rather than on its own.

  Scopes only ever **narrow**. They are checked in addition to what the actor
  behind the credential may already do, never instead of it, so a scope can
  take access away but never grant it.
  """

  import Ecto.Changeset

  alias Portal.Authentication.Credential
  alias Portal.Authentication.Subject

  @levels_by_entity [
    account: [:read],
    actors: [:read, :write],
    groups: [:read, :write],
    external_identities: [:read, :write],
    clients: [:read, :write],
    client_tokens: [:read, :write],
    sites: [:read, :write],
    gateways: [:read, :write],
    gateway_tokens: [:write],
    resources: [:read, :write],
    policies: [:read, :write],
    auth_providers: [:read],
    directories: [:read],
    posture_providers: [:read],
    logs: [:read]
  ]

  @entities Keyword.keys(@levels_by_entity)
  @all for {entity, levels} <- @levels_by_entity, level <- levels, do: "#{entity}:#{level}"

  @doc "Every entity this API exposes, in display order."
  def entities, do: @entities

  @doc "Every entity paired with the levels it supports."
  def levels_by_entity, do: @levels_by_entity

  @doc "The levels `entity` supports."
  def levels(entity), do: Keyword.get(@levels_by_entity, entity, [])

  @doc "Every scope a credential may hold."
  def all, do: @all

  @doc "Builds the scope string for an entity and level."
  def to_string(entity, level), do: "#{entity}:#{level}"

  @doc """
  The scope an operation requires.

  Anything that is not a read is a write, so a verb nobody anticipated is never
  treated as readable. An entity with no read level requires write even to be
  read, which is stricter rather than looser.
  """
  def required(entity, :get) do
    if :read in levels(entity) do
      to_string(entity, :read)
    else
      to_string(entity, :write)
    end
  end

  def required(entity, method) when is_atom(method), do: to_string(entity, :write)

  @doc """
  Whether `subject` may act on `entity` with an HTTP `method`.

  Mirrors `Portal.Safe.permit/3`, which answers the same question for the
  actor's type, and composes with it rather than replacing it: a subject has to
  satisfy both, so a scope can withhold access but never grant it.

  Checked once at the API boundary rather than per data access, because one
  request routinely touches several schemas - creating a policy reads a group
  and a resource on the way - and the required scopes should follow the
  operation the caller asked for, not the lookups a changeset happens to do.
  """
  def permit(entity, method, %Subject{credential: %Credential{scopes: scopes}}) do
    required = required(entity, method)

    if satisfies?(scopes, required) do
      :ok
    else
      {:error, {:unauthorized, required_scope: required}}
    end
  end

  @doc """
  Whether `granted` satisfies `required`.

  `nil` means the credential type does not carry scopes at all, and is
  unrestricted. API tokens always carry an explicit list.
  """
  def satisfies?(nil, _required), do: true

  def satisfies?(granted, required) when is_list(granted) do
    expanded = expand(granted)
    Enum.all?(List.wrap(required), &(&1 in expanded))
  end

  @doc "Adds the scopes implied by the ones granted, so write covers read."
  def expand(scopes) when is_list(scopes) do
    scopes
    |> Enum.flat_map(&implied/1)
    |> Enum.uniq()
  end

  defp implied(scope) do
    case split(scope) do
      {:ok, entity, :write} -> with_implied_read(entity)
      {:ok, entity, :read} -> [to_string(entity, :read)]
      :error -> []
    end
  end

  defp with_implied_read(entity) do
    if :read in levels(entity) do
      [to_string(entity, :read), to_string(entity, :write)]
    else
      [to_string(entity, :write)]
    end
  end

  @doc """
  Parses a space delimited `scope` parameter.

  An absent or empty parameter is an error rather than a default: a caller that
  omits it should be told, not handed a silent grant.
  """
  def parse(nil), do: {:error, :missing}
  def parse(""), do: {:error, :missing}

  def parse(scope) when is_binary(scope) do
    requested = scope |> String.split(" ", trim: true) |> Enum.uniq()

    case {requested, Enum.reject(requested, &known?/1)} do
      {[], _unknown} -> {:error, :missing}
      {_requested, []} -> {:ok, expand(requested)}
      {_requested, unknown} -> {:error, {:unknown, unknown}}
    end
  end

def description(:account), do: "Read the account's details and limits."
  def description(:actors), do: "List, create, edit and delete actors."

  def description(:auth_providers),
    do: "List the identity providers people sign in through."

  def description(:client_tokens),
    do: "List client tokens, and mint or revoke the tokens a device signs in with."

  def description(:clients),
    do: "List, edit and delete clients, and mark them verified."

  def description(:directories),
    do: "List the directories that sync actors and groups."

  def description(:external_identities),
    do: "List an actor's linked identities, and unlink them."

  def description(:gateway_tokens),
    do: "Mint, rotate and revoke the tokens gateways join a site with."

  def description(:gateways),
    do: "List, create, edit and delete the gateways serving a site."

  def description(:groups),
    do: "List, create, edit and delete groups, and change who belongs to them."

  def description(:logs), do: "Read change, session, flow and API request logs."

  def description(:policies),
    do: "List, create, edit and delete the policies granting access."

  def description(:posture_providers),
    do: "List posture providers and the devices they report."

  def description(:resources),
    do: "List, create, edit and delete resources and their pool members."

  def description(:sites), do: "List, create, edit and delete sites."

  @doc "How an entity is named in the UI and on the consent screen."
  def label(:auth_providers), do: "Authentication providers"

  def label(entity) do
    entity
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> :string.titlecase()
  end

  @doc """
  The scopes behind a picker's shortcut buttons.

  Anything unrecognised selects nothing, so a tampered value cannot widen a
  grant.
  """
  def preset("all"), do: all()

  def preset("read") do
    for {entity, levels} <- @levels_by_entity, :read in levels, do: to_string(entity, :read)
  end

  def preset(_other), do: []

  @doc "Renders scopes back into a space delimited parameter."
  def encode(scopes), do: Enum.join(scopes, " ")

  @doc "Whether this server issues `scope`."
  def known?(scope), do: scope in @all

  @doc """
  Validates a `scopes` field.

  An empty list is rejected: a credential that can reach nothing is a
  configuration mistake rather than a thing worth minting.
  """
  def validate(changeset, field) do
    validate_change(changeset, field, fn ^field, scopes ->
      cond do
        scopes == [] ->
          [{field, "must grant at least one scope"}]

        unknown = scopes |> Enum.reject(&known?/1) |> Enum.take(3) |> presence() ->
          [{field, "contains unknown scopes: #{Enum.join(unknown, ", ")}"}]

        true ->
          []
      end
    end)
  end

  defp presence([]), do: nil
  defp presence(list), do: list

  defp split(scope) when is_binary(scope) do
    with [entity, level] <- String.split(scope, ":", parts: 2),
         {:ok, entity} <- existing_entity(entity),
         {:ok, level} <- existing_level(entity, level) do
      {:ok, entity, level}
    else
      _invalid -> :error
    end
  end

  defp existing_entity(entity) do
    atom = String.to_existing_atom(entity)
    if atom in @entities, do: {:ok, atom}, else: :error
  rescue
    ArgumentError -> :error
  end

  defp existing_level(entity, level) do
    atom = String.to_existing_atom(level)
    if atom in levels(entity), do: {:ok, atom}, else: :error
  rescue
    ArgumentError -> :error
  end
end
