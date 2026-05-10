defmodule Lua.VM.Display.NativeFunc do
  @moduledoc """
  Display wrapper for a native Elixir-backed Lua function
  (`{:native_func, fun}`) returned across the `Lua.eval!/2` boundary.

  Carries the underlying function so the `Inspect` impl can render
  the captured `module/function/arity`, falling back to the fun's
  default inspect output for anonymous functions.

  ## Fields

  - `:fun` — the Elixir function passed to `Lua.set!/3` or installed
    via `deflua`.
  - `:ref` — the original `{:native_func, fun}` tuple so callers can
    still pass it back to `Lua.call_function/3`.

  The wrap fires in both `decode: true` and `decode: false` modes —
  raw `{:native_func, fun}` tuples have always leaked to the user.
  Internal pattern matches against `{:native_func, _}` are unaffected.
  """

  @type t :: %__MODULE__{
          fun: function(),
          ref: tuple()
        }

  defstruct [:fun, :ref]

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Lua.VM.Display.NativeFunc{fun: fun}, opts) do
      concat([
        "#Lua.NativeFunc<",
        to_doc(fun, opts),
        ">"
      ])
    end
  end
end
