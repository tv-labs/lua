defmodule Lua.RuntimeException do
  @moduledoc """
  Raised when a Lua program fails at runtime — bad argument types,
  arithmetic on a non-number, indexing a nil, an explicit `error()`
  call from Lua, or any other dynamic failure inside the VM.

  `Exception.message/1` returns a plain, single-line, ANSI-free string — the
  error body plus a compact ` (at source:line)` suffix — safe to drop into a
  `Logger` call or an error tracker. There is no `:message` struct field; the
  message is composed lazily from `:original` (and the semantic fields below),
  so there is no field that reads back `nil` for the common case of a wrapped
  VM error.

  For a rich, human-readable report (location header, stack trace, suggestions,
  and ANSI color on a TTY) use `Lua.format_exception/1` — this is what
  `mix lua.eval` prints. For structured error reporting (JSON, a UI) use
  `to_map/2`.

  Fields:

    * `:original`    — the underlying VM error term
    * `:kind`        — the category of failure: `:error` (an explicit `error()`
      call), `:type`, `:argument`, `:assertion`, or `:internal`; `nil` for
      host-side API errors that don't originate from a Lua value
    * `:value`       — the raised Lua value (per §6.1), as `pcall`/`xpcall`
      would hand it back; `nil` when there is no Lua-side value
    * `:state`       — the internal VM state at the point of failure
    * `:line`        — line number where the error was raised
    * `:source`      — source name (filename or the default `<eval>`)
    * `:call_stack`  — list of Lua frames at failure
  """
  alias Lua.Util
  alias Lua.VM.ArgumentError
  alias Lua.VM.AssertionError
  alias Lua.VM.InternalError
  alias Lua.VM.ProtectedCall
  alias Lua.VM.RuntimeError
  alias Lua.VM.TypeError

  @runtime_prefix "Lua runtime error: "

  @type kind :: :error | :type | :argument | :assertion | :internal

  @type t :: %__MODULE__{}

  defexception [:original, :kind, :value, :state, :line, :source, :call_stack]

  @impl true
  def exception({:lua_error, error, _state}) do
    %__MODULE__{original: error}
  end

  def exception(list) when is_list(list) do
    # Validate the descriptor eagerly so a missing key fails at the raise site
    # rather than lazily inside `message/1`. The list itself is the semantic
    # source — `message/1` reads `:scope`/`:function`/`:message` back off it.
    Keyword.fetch!(list, :scope)
    Keyword.fetch!(list, :function)
    Keyword.fetch!(list, :message)

    %__MODULE__{original: list}
  end

  def exception(error) when is_binary(error) do
    %__MODULE__{original: String.trim(error)}
  end

  def exception(error) do
    # Copy structured fields off VM exceptions (TypeError, RuntimeError,
    # AssertionError, ArgumentError, InternalError) so consumers can
    # pattern-match on `:kind` / `:value` / `:line` / `:source` without having
    # to re-parse the message string. `:kind`/`:value` come back `nil` for
    # arbitrary Elixir exceptions, which carry no Lua-side value.
    {line, source, call_stack} = extract_context(error)
    kind = kind(error)

    # No message is stored — `message/1` renders the wrapped error lazily. The
    # inner VM exceptions gate ANSI on `IO.ANSI.enabled?/0` at render time
    # (issue #384); freezing their rendered message here would bake in escape
    # codes from the TTY-attached VM process and leak them into log sinks.
    %__MODULE__{
      original: error,
      kind: kind,
      value: kind && ProtectedCall.error_value(error),
      line: line,
      source: source,
      call_stack: call_stack
    }
  end

  # Plain, single-line, ANSI-free rendering. The wrapped VM exception's
  # `message/1` returns just the error body; we prefix it and append the Lua
  # source location so a log line carries the "where" without a multi-line
  # block. The rich render lives in `format/1`.
  @impl true
  def message(%__MODULE__{original: original} = e) when is_exception(original) do
    prefix_message(Exception.message(original)) <> location_suffix(e)
  end

  def message(%__MODULE__{original: list}) when is_list(list) do
    prefix_message("#{format_function(list[:scope], list[:function])} failed, #{list[:message]}")
  end

  def message(%__MODULE__{original: binary}) when is_binary(binary) do
    prefix_message(String.trim(binary))
  end

  def message(%__MODULE__{original: {tag, _, _} = term}) when tag in [:badarith, :illegal_index] do
    prefix_message(Util.format_error(term))
  end

  def message(%__MODULE__{original: original}) do
    prefix_message(inspect(original))
  end

  @doc """
  Renders the rich, multi-line report for this error — location header, stack
  trace, and suggestions — with ANSI color when `IO.ANSI.enabled?/0` is true.

  This is the terminal/REPL rendering `mix lua.eval` prints and what
  `Lua.format_exception/1` delegates to. For the plain, single-line, log-safe
  string use `Exception.message/1`; for structured data use `to_map/2`.
  """
  @spec format(t()) :: String.t()
  def format(%__MODULE__{original: original}) when is_exception(original) do
    prefix_message(rich(original))
  end

  def format(%__MODULE__{} = e), do: message(e)

  @doc """
  Returns a wire-safe structured map — `message`, `source`, `line`,
  `call_stack`, `source_context`, `suggestion`, `error_kind` — with no ANSI
  escapes in any field. Intended for JSON payloads, structured logs, and
  UI-facing error reporting.

  Pass `:source_code` to populate `source_context`. Wrapped VM errors delegate
  to their own `to_map/2`; host-side errors (no Lua value) return a minimal map.
  """
  @spec to_map(t(), keyword()) :: map()
  def to_map(exception, opts \\ [])

  def to_map(%__MODULE__{original: %RuntimeError{} = o}, opts), do: RuntimeError.to_map(o, opts)

  def to_map(%__MODULE__{original: %TypeError{} = o}, opts), do: TypeError.to_map(o, opts)

  def to_map(%__MODULE__{original: %AssertionError{} = o}, opts), do: AssertionError.to_map(o, opts)

  def to_map(%__MODULE__{original: %ArgumentError{} = o}, opts), do: ArgumentError.to_map(o, opts)

  def to_map(%__MODULE__{} = e, _opts), do: minimal_map(e)

  defp rich(%RuntimeError{} = o), do: RuntimeError.format(o)
  defp rich(%TypeError{} = o), do: TypeError.format(o)
  defp rich(%AssertionError{} = o), do: AssertionError.format(o)
  defp rich(%ArgumentError{} = o), do: ArgumentError.format(o)
  defp rich(%InternalError{} = o), do: InternalError.format(o)
  defp rich(other), do: Exception.message(other)

  defp minimal_map(%__MODULE__{} = e) do
    %{
      type: nil,
      message: message(e),
      source: e.source,
      line: e.line,
      call_stack: e.call_stack || [],
      source_context: nil,
      suggestion: nil,
      error_kind: nil
    }
  end

  defp location_suffix(%__MODULE__{source: source, line: line}) when not is_nil(source) and not is_nil(line),
    do: " (at #{source}:#{line})"

  defp location_suffix(%__MODULE__{source: source}) when not is_nil(source), do: " (at #{source})"
  defp location_suffix(%__MODULE__{line: line}) when not is_nil(line), do: " (at line #{line})"
  defp location_suffix(_), do: ""

  defp prefix_message(@runtime_prefix <> _ = msg), do: msg
  defp prefix_message(msg), do: @runtime_prefix <> msg

  defp extract_context(error) when is_struct(error) do
    {Map.get(error, :line), Map.get(error, :source), Map.get(error, :call_stack)}
  end

  defp extract_context(_), do: {nil, nil, nil}

  # Classify a wrapped VM exception into its user-facing category. Arbitrary
  # Elixir exceptions (no Lua-side value) return `nil`.
  defp kind(%RuntimeError{}), do: :error
  defp kind(%TypeError{}), do: :type
  defp kind(%ArgumentError{}), do: :argument
  defp kind(%AssertionError{}), do: :assertion
  defp kind(%InternalError{}), do: :internal
  defp kind(_), do: nil

  defp format_function([], function), do: "#{function}()"

  defp format_function(scope, function) do
    "#{Enum.join(scope, ".")}.#{function}()"
  end
end
