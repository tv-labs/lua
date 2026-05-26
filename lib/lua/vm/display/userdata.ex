defmodule Lua.VM.Display.Userdata do
  @moduledoc """
  Display wrapper for a Lua userdata reference (`{:udref, id}`)
  returned across the `Lua.eval!/2` boundary in
  `decode: false` mode.

  Default `decode: true` returns `{:userdata, term}` and is unaffected
  by this wrap.

  ## Fields

  - `:id` — the integer id of the underlying `{:udref, id}` reference.
  - `:term` — the wrapped Elixir term, looked up at the time the eval
    boundary was crossed.
  - `:ref` — the original `{:udref, id}` tuple so callers can
    round-trip the value back into the VM (via `Lua.set!/3`,
    `Lua.encode!/2`, etc.).

  Internal pattern matches against `{:udref, _}` are unaffected; the
  wrap is a display affordance applied at the eval boundary only.
  """

  @type t :: %__MODULE__{
          id: non_neg_integer(),
          term: term(),
          ref: tuple()
        }

  defstruct [:id, :term, :ref]

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Lua.VM.Display.Userdata{id: id, term: term}, opts) do
      concat([
        "#Lua.Userdata<id: ",
        Integer.to_string(id),
        ", term: ",
        to_doc(term, opts),
        ">"
      ])
    end
  end
end
