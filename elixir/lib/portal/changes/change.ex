defmodule Portal.Changes.Change do
  @moduledoc """
  A decoded row change. `lsn` orders changes in delivery order: the commit LSN
  of the change's transaction in the high 64 bits, the change's own WAL LSN in
  the low 64 bits. See `Portal.Changes.Consumer`.
  """
  defstruct [:lsn, :op, :old_struct, :struct]

  @type t :: %__MODULE__{
          lsn: non_neg_integer(),
          op: :insert | :update | :delete,
          old_struct: struct() | nil,
          struct: struct() | nil
        }
end
