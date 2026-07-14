defmodule Portal.LogSinks.FieldType do
  @moduledoc """
  Registry of every envelope field the delivery engine has ever shipped and
  its wire type.

  Destinations remember field types forever (Elasticsearch mappings are
  immutable), so an existing field changing type breaks customer indices that
  already ingested it. Fields register themselves the first time they are
  delivered; a later delivery observing a different type for a registered
  field is one of our releases breaking the contract, and pages us via an
  error-level log. Add a NEW field instead of retyping an existing one.

  Top-level envelope fields register unqualified. Free-form payload interiors
  register under their producer ("change.resources.port",
  "session.subject.actor_id"), because paths inside before/after legitimately
  differ in type across tables.
  """
  # credo:disable-for-this-file Credo.Check.Warning.MissingChangesetFunction
  use Ecto.Schema

  @primary_key false
  schema "log_sink_field_types" do
    field :name, :string, primary_key: true
    field :type, :string
    field :inserted_at, :utc_datetime_usec
  end
end
