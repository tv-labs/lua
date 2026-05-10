defmodule Lua.VM.Display.Closure do
  @moduledoc """
  Display wrapper for a Lua closure (`{:lua_closure, proto, upvalues}`)
  returned across the `Lua.eval!/2` boundary.

  Carries the closure's source, line, and arity for human display.
  The wrap fires in both `decode: true` and `decode: false` modes
  because raw closure tuples have always leaked to the user.

  ## Fields

  - `:source` — source name attached to the closure's prototype
    (for example `"<eval>"` or `"my_script.lua"`).
  - `:line` — first line of the closure's body, derived from the
    prototype's `:lines` field.
  - `:arity` — the number of declared parameters. Variadic closures
    have `:arity` equal to the fixed-parameter count; the variadic
    flag is reflected by appending `+...` in the inspect output.
  - `:vararg?` — true when the closure accepts varargs (`...`).
  - `:ref` — the original `{:lua_closure, proto, upvalues}` tuple
    so callers can still reach the live closure (for example via
    `Lua.call_function/3`).

  Internal pattern matches against `{:lua_closure, _, _}` are
  unaffected; the wrap is a display affordance applied at the eval
  boundary only.
  """

  @type t :: %__MODULE__{
          source: binary(),
          line: non_neg_integer(),
          arity: non_neg_integer(),
          vararg?: boolean(),
          ref: tuple()
        }

  defstruct [:source, :line, :arity, :vararg?, :ref]

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Lua.VM.Display.Closure{} = c, opts) do
      arity = Integer.to_string(c.arity || 0)
      arity = if c.vararg?, do: arity <> "+...", else: arity

      concat([
        "#Lua.Closure<source: ",
        to_doc(c.source, opts),
        ", line: ",
        Integer.to_string(c.line || 0),
        ", arity: ",
        arity,
        ">"
      ])
    end
  end
end
