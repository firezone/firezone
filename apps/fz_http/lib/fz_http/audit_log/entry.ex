# defmodule FzHttp.AuditLog.Entry do
#   use FzHttp, :schema

#   schema "auditlog_entries" do
#     field :resource, :string
#     field :action, :string

#     embeds_many :changes, Change, primary_key: false do
#       field :field, :string
#       field :previous_value, :string
#       field :new_value, :string
#     end

#     field :metadata, :map, default: %{}

#     belongs_to :user, TalkInto.Domain.Users.User

#     timestamps(updated_at: false)
#   end
# end
