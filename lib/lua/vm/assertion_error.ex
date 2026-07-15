defmodule Lua.VM.AssertionError do
  @moduledoc false

  # Internal VM exception. Never surfaces to the host directly — it is wrapped
  # into the public `Lua.RuntimeException` (kind: `:assertion`) at the API
  # boundary.
  #
  # Raised by the Lua `assert()` function when the condition is falsy. When
  # raised without explicit `:line` / `:source` opts, `exception/1` populates
  # them from the calling Lua source position via
  # `Lua.VM.Executor.current_position/0`.

  alias Lua.VM.ErrorFormatter

  @type t :: %__MODULE__{}

  # `:state` carries the `Lua.VM.State` as of the raise, so protected calls
  # (pcall/xpcall) can keep heap effects made before the error instead of
  # rolling back to their entry snapshot. It is out-of-band metadata: it never
  # participates in `message` and stays `nil` when no state was in scope.
  @derive {Inspect, except: [:state]}
  defexception [:value, :source, :call_stack, :line, :state]

  @impl true
  def exception(opts) do
    {auto_line, auto_source} = Lua.VM.Executor.current_position()

    %__MODULE__{
      value: Keyword.get(opts, :value),
      source: Keyword.get(opts, :source) || auto_source,
      call_stack: Keyword.get(opts, :call_stack, []),
      line: Keyword.get(opts, :line) || auto_line,
      state: Keyword.get(opts, :state)
    }
  end

  # Rendered lazily so `IO.ANSI.enabled?/0` is evaluated when the message is
  # actually written rather than frozen at construction time. See issue #384;
  # mirrors `Lua.VM.ArgumentError.message/1`.
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
    ErrorFormatter.to_map(:assertion_error, raw_message(error.value),
      source: error.source,
      line: error.line,
      call_stack: error.call_stack,
      source_code: Keyword.get(opts, :source_code)
    )
  end

  defp format_message(value, source, line, call_stack) do
    ErrorFormatter.format(:assertion_error, raw_message(value),
      source: source,
      line: line,
      call_stack: call_stack
    )
  end

  defp raw_message(value), do: "assertion failed: #{stringify(value)}"

  defp stringify(nil), do: "nil"
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v), do: inspect(v)
end
