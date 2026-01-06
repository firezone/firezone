defmodule Portal.Changes.Change do
  defstruct [:lsn, :op, :old_struct, :struct]

  @type t :: %__MODULE__{
          lsn: integer(),
          op: :insert | :update | :delete,
          old_struct: struct() | nil,
          struct: struct() | nil
        }
end
