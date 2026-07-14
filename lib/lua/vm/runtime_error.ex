defmodule Lua.VM.RuntimeError do
  @moduledoc """
  Raised by the Lua `error()` function.

  Carries the original Lua error value, which may be any Lua type (string,
  number, table reference, etc.).

  When raised without explicit `:line` / `:source` opts (e.g. from a stdlib
  bad-argument check), `exception/1` populates them from the calling Lua
  source position via `Lua.VM.Executor.current_position/0`. That position
  is stashed in the process dictionary at every native-call boundary, so
  any raise site reachable from a Lua execution inherits the correct
  attribution automatically.
  """

  alias Lua.VM.ErrorFormatter
  alias Lua.VM.Value

  @type t :: %__MODULE__{}

  # `:state` carries the `Lua.VM.State` as of the raise, so protected calls
  # (pcall/xpcall) can keep heap effects made before the error instead of
  # rolling back to their entry snapshot. It is out-of-band metadata: it never
  # participates in `message` and stays `nil` when no state was in scope.
  #
  # `:lua_value` is Lua-facing only: when `error()` raises a string message,
  # it carries the §6.1 `source:line:`-prefixed view that `pcall`/`xpcall`
  # hand back to Lua code. It is NEVER read by `message`, `to_map`,
  # `format_message`, `raw_message`, or `stringify` — those keep reading the
  # raw `:value`, so host-facing rendering (which adds its own
  # `at source:line:` header) never doubles the location.
  @derive {Inspect, except: [:state]}
  defexception [:value, :lua_value, :source, :call_stack, :line, :state]

  @impl true
  def exception(opts) do
    {auto_line, auto_source} = Lua.VM.Executor.current_position()

    %__MODULE__{
      value: Keyword.get(opts, :value),
      lua_value: Keyword.get(opts, :lua_value),
      source: Keyword.get(opts, :source) || auto_source,
      call_stack: Keyword.get(opts, :call_stack, []),
      line: Keyword.get(opts, :line) || auto_line,
      state: Keyword.get(opts, :state)
    }
  end

  # Rendered lazily so `IO.ANSI.enabled?/0` is evaluated when the message is
  # actually written (log sink, TTY, Sentry) rather than frozen at construction
  # time — where it would run inside a Lua execution and always see a TTY. See
  # issue #384; mirrors `Lua.VM.ArgumentError.message/1`.
  @impl true
  def message(%__MODULE__{} = error) do
    format_message(error.value, error.source, error.line, error.call_stack)
  end

  @doc """
  Returns a wire-safe structured map for this error. See
  `Lua.VM.ErrorFormatter.to_map/3` for the shape.

  Pass `:source_code` to populate `source_context`.
  """
  @spec to_map(t(), keyword()) :: map()
  def to_map(%__MODULE__{} = error, opts \\ []) do
    ErrorFormatter.to_map(:runtime_error, raw_message(error.value),
      source: error.source,
      line: error.line,
      call_stack: error.call_stack,
      source_code: Keyword.get(opts, :source_code)
    )
  end

  defp format_message(value, source, line, call_stack) do
    ErrorFormatter.format(:runtime_error, raw_message(value),
      source: source,
      line: line,
      call_stack: call_stack
    )
  end

  defp raw_message(value), do: "runtime error: #{stringify(value)}"

  # PUC-Lua renders string and number error objects verbatim, but any other
  # Lua value (table, function, boolean, nil, userdata) becomes the message
  # "(error object is a TYPE value)" rather than leaking an internal term.
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v) when is_integer(v) or is_float(v), do: Value.to_string(v)

  defp stringify(value) do
    "(error object is a #{Value.type_name(value)} value)"
  end
end
