defmodule Lua.VM.Stdlib.Io do
  @moduledoc """
  Lua 5.3 `io` standard library.

  The `io` table is exposed as a table of functions with `stdin`/`stdout`/
  `stderr` handles, matching reference Lua's shape so user code that lifts
  patterns from the wider ecosystem (and the Lua 5.3 suite) does not trip on
  `attempt to index a function value`.

  Every entry is currently a sandbox stub that raises on call — virtualizing
  `io` over the VFS (and a host-backed variant) is a follow-up. The
  table-of-functions shape is preserved regardless.
  """

  @behaviour Lua.VM.Stdlib.Library

  alias Lua.VM.State
  alias Lua.VM.Stdlib.Sandbox

  # The full reference `io` surface. Every key is stubbed for now; the shape is
  # what matters (see moduledoc).
  @io_functions ~w(read write open close lines popen tmpfile output input flush type)
  @io_handles ~w(stdin stdout stderr)

  @impl true
  def lib_name, do: "io"

  @impl true
  def install(state) do
    io_table =
      Map.new(@io_functions ++ @io_handles, fn name ->
        {name, Sandbox.stub([:io, String.to_atom(name)])}
      end)

    {tref, state} = State.alloc_table(state, io_table)
    State.set_global(state, "io", tref)
  end
end
