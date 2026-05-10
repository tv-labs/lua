defmodule Lua.VM.Display do
  @moduledoc """
  Boundary wrappers that turn opaque VM value tags into display
  structs at the `Lua.eval!/2` return path.

  The internal VM continues to use the tagged-tuple representation
  (`{:tref, id}`, `{:lua_closure, proto, upvalues}`,
  `{:native_func, fun}`, `{:udref, id}`). These wrappers exist
  purely so that values that surface to user code in `iex` render
  legibly instead of as opaque tuples.

  See `Lua.VM.Display.Table`, `Lua.VM.Display.Closure`,
  `Lua.VM.Display.NativeFunc`, and `Lua.VM.Display.Userdata` for
  the per-tag display structs and their `Inspect` impls.

  ## Decode behaviour

  | Tag                    | `decode: true`                   | `decode: false`              |
  |------------------------|----------------------------------|------------------------------|
  | `{:tref, _}`           | list of `{k, v}` (unchanged)     | wraps to `Display.Table`     |
  | `{:udref, _}`          | `{:userdata, term}` (unchanged)  | wraps to `Display.Userdata`  |
  | `{:lua_closure, _, _}` | wraps to `Display.Closure`       | wraps to `Display.Closure`   |
  | `{:native_func, _}`    | wraps to `Display.NativeFunc`    | wraps to `Display.NativeFunc`|

  Default-decode tables and userdata are left in their existing
  Elixir-friendly shape so `deflua` flows and downstream consumers
  do not need to change.
  """

  alias Lua.VM.Display.Closure
  alias Lua.VM.Display.NativeFunc
  alias Lua.VM.Display.Table, as: DTable
  alias Lua.VM.Display.Userdata
  alias Lua.VM.State

  @typedoc "Any of the four display structs produced at the eval boundary."
  @type display_struct ::
          DTable.t()
          | Closure.t()
          | NativeFunc.t()
          | Userdata.t()

  @doc """
  Wraps each value in a list of eval results for display, given the
  state at boundary-cross time and the `decode:` option.

  When `decode: true` (the default), tables and userdata are passed
  through unchanged because they have already been decoded into
  Elixir-friendly shapes (list of tuples and `{:userdata, term}`).
  Closures and native funcs are wrapped in either mode.

  When `decode: false`, all four tag kinds are wrapped; nested values
  inside tables are also wrapped via `wrap_value/2`.
  """
  @spec wrap_results([term()], State.t(), boolean()) :: [term()]
  def wrap_results(values, state, decode?) when is_list(values) do
    Enum.map(values, &wrap_value(&1, state, decode?))
  end

  @doc """
  Returns true when the value is one of the four display structs.

  Used by API entry points (`Lua.set!/3`, `Lua.encode!/2`, etc.) to
  detect a wrapped-for-display value that should be unwrapped back
  to its underlying VM tag before further processing.
  """
  @spec display_struct?(term()) :: boolean()
  def display_struct?(%DTable{}), do: true
  def display_struct?(%Closure{}), do: true
  def display_struct?(%NativeFunc{}), do: true
  def display_struct?(%Userdata{}), do: true
  def display_struct?(_), do: false

  @doc """
  Unwraps a display struct back to its underlying VM tag tuple.

  Returns the value unchanged if it is not a display struct.
  """
  @spec unwrap(term()) :: term()
  def unwrap(%DTable{ref: ref}), do: ref
  def unwrap(%Closure{ref: ref}), do: ref
  def unwrap(%NativeFunc{ref: ref}), do: ref
  def unwrap(%Userdata{ref: ref}), do: ref
  def unwrap(other), do: other

  @doc """
  Wraps a single eval-result value for display.

  See `wrap_results/3` for the decode-mode matrix.
  """
  @spec wrap_value(term(), State.t(), boolean()) :: term()
  def wrap_value(value, state, decode?)

  # decode: true — only wrap closures/native; tables and userdata
  # have already been decoded and are passed through unchanged.
  def wrap_value({:lua_closure, _, _} = ref, _state, _decode?) do
    wrap_closure(ref)
  end

  def wrap_value({:native_func, fun} = ref, _state, _decode?) do
    %NativeFunc{fun: fun, ref: ref}
  end

  # decode: false — wrap tref/udref too, and recurse into table peek.
  def wrap_value({:tref, id} = ref, state, false) do
    peek = peek_table(state, id, false)
    %DTable{id: id, peek: peek, ref: ref}
  end

  def wrap_value({:udref, id} = ref, state, false) do
    term = State.get_userdata(state, ref)
    %Userdata{id: id, term: term, ref: ref}
  end

  # decode: true catch-all (already-decoded values pass through)
  def wrap_value(value, _state, _decode?), do: value

  # ---- internal helpers ----

  defp wrap_closure({:lua_closure, proto, _upvalues} = ref) do
    {first_line, _last_line} = proto.lines || {0, 0}

    %Closure{
      source: proto.source,
      line: first_line,
      arity: proto.param_count,
      vararg?: proto.is_vararg,
      ref: ref
    }
  end

  # Build a `peek` value for an unencoded table reference. Sequences
  # (1..N keys) render as a list; mixed-key tables render as a map.
  # Nested tables/closures are recursively wrapped so `Inspect` does
  # not have to know about live VM state.
  defp peek_table(state, id, decode?) do
    case Map.fetch(state.tables, id) do
      {:ok, table} ->
        data = table.data

        if sequence_like?(data) do
          Enum.map(1..map_size(data), &wrap_value(Map.fetch!(data, &1), state, decode?))
        else
          Map.new(data, fn {k, v} -> {k, wrap_value(v, state, decode?)} end)
        end

      :error ->
        # Stale or detached reference. Render an empty peek rather
        # than crashing — the `id` field is enough to identify it.
        []
    end
  end

  defp sequence_like?(data) when map_size(data) == 0, do: false

  defp sequence_like?(data) do
    Enum.all?(1..map_size(data), &Map.has_key?(data, &1))
  end
end
