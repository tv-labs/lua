defmodule Lua.VM.TypeError do
  @moduledoc false

  # Internal VM exception. Never surfaces to the host directly — it is wrapped
  # into the public `Lua.RuntimeException` (kind: `:type`) at the API boundary.
  #
  # Raised when a Lua operation is applied to a value of the wrong type.
  # Examples: calling a nil value, calling a number, indexing a boolean.
  #
  # When raised without explicit `:line` / `:source` opts (e.g. from a stdlib
  # type check), `exception/1` populates them from the calling Lua source
  # position via `Lua.VM.Executor.current_position/0`. That position is stashed
  # in the process dictionary at every native-call boundary, so any raise site
  # reachable from a Lua execution inherits the correct attribution
  # automatically.

  alias Lua.VM.ErrorFormatter

  @type t :: %__MODULE__{}

  # `:state` carries the `Lua.VM.State` as of the raise, so protected calls
  # (pcall/xpcall) can keep heap effects made before the error instead of
  # rolling back to their entry snapshot. It is out-of-band metadata: it never
  # participates in `message` and stays `nil` when no state was in scope.
  @derive {Inspect, except: [:state]}
  defexception [:value, :source, :call_stack, :line, :error_kind, :value_type, :state]

  @impl true
  def exception(opts) do
    {auto_line, auto_source} = Lua.VM.Executor.current_position()

    %__MODULE__{
      value: Keyword.get(opts, :value),
      source: Keyword.get(opts, :source) || auto_source,
      call_stack: Keyword.get(opts, :call_stack, []),
      line: Keyword.get(opts, :line) || auto_line,
      error_kind: Keyword.get(opts, :error_kind),
      value_type: Keyword.get(opts, :value_type),
      state: Keyword.get(opts, :state)
    }
  end

  # Rendered lazily so `IO.ANSI.enabled?/0` is evaluated when the message is
  # actually written rather than frozen at construction time. See issue #384;
  # mirrors `Lua.VM.ArgumentError.message/1`.
  @impl true
  def message(%__MODULE__{} = error) do
    format_message(
      error.value,
      error.source,
      error.line,
      error.call_stack,
      error.error_kind,
      error.value_type
    )
  end

  @doc """
  Returns a wire-safe structured map for this error. See
  `Lua.VM.ErrorFormatter.to_map/3` for the shape.

  Pass `:source_code` to populate `source_context`.
  """
  @spec to_map(t(), keyword()) :: map()
  def to_map(%__MODULE__{} = error, opts \\ []) do
    ErrorFormatter.to_map(:type_error, raw_message(error.value),
      source: error.source,
      line: error.line,
      call_stack: error.call_stack,
      error_kind: error.error_kind,
      value_type: error.value_type,
      source_code: Keyword.get(opts, :source_code)
    )
  end

  defp format_message(value, source, line, call_stack, error_kind, value_type) do
    ErrorFormatter.format(:type_error, raw_message(value),
      source: source,
      line: line,
      call_stack: call_stack,
      error_kind: error_kind,
      value_type: value_type
    )
  end

  defp raw_message(value), do: stringify(value)

  defp stringify(nil), do: "nil"
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v), do: inspect(v)
end
