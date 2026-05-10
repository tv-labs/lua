defmodule Lua.VM.Display.Table do
  @moduledoc """
  Display wrapper for a Lua table reference returned across the
  `Lua.eval!/2` boundary in `decode: false` mode.

  Carries a snapshot of the table's contents (`:peek`) so the
  `Inspect` impl does not need access to live VM state. The wrap is
  a display affordance only — internally the VM still uses the
  `{:tref, id}` tuple, and pattern-matches against that tag remain
  the supported way to detect a table reference.

  ## Fields

  - `:id` — the integer id of the underlying `{:tref, id}` reference.
  - `:peek` — a snapshot of the table's data as it was at the time
    the eval boundary was crossed, suitable for human display. May
    be a list (sequence-like tables) or a map (mixed-key tables).
    Truncated to `Inspect.Opts.limit` entries when rendered.
  - `:ref` — the original `{:tref, id}` tuple so callers can
    round-trip the value back into the VM (via `Lua.set!/3`,
    `Lua.encode!/2`, etc.).

  See `Lua.eval!/3` and the `decode:` option.
  """

  @type t :: %__MODULE__{
          id: non_neg_integer(),
          peek: list() | map(),
          ref: tuple()
        }

  defstruct [:id, :peek, :ref]

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Lua.VM.Display.Table{id: id, peek: peek}, opts) do
      concat([
        "#Lua.Table<id: ",
        Integer.to_string(id),
        ", ",
        to_doc(peek, opts),
        ">"
      ])
    end
  end
end
