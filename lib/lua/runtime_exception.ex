defmodule Lua.RuntimeException do
  @moduledoc """
  Raised when a Lua program fails at runtime — bad argument types,
  arithmetic on a non-number, indexing a nil, an explicit `error()`
  call from Lua, or any other dynamic failure inside the VM.

  Always render with `Exception.message/1` — there is no `:message` struct
  field. The message is composed lazily from `:original` (and the semantic
  fields below) so ANSI color is gated on `IO.ANSI.enabled?/0` at output time
  rather than frozen at construction (issue #384), and so there is no field
  that reads back `nil` for the common case of a wrapped VM error.

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
  alias Lua.VM.ProtectedCall

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

  # Everything renders lazily from `:original`, so the ANSI gate on wrapped VM
  # exceptions is evaluated when the message is written, not frozen here.
  @impl true
  def message(%__MODULE__{original: original}) when is_exception(original) do
    prefix_message(Exception.message(original))
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

  defp prefix_message(@runtime_prefix <> _ = msg), do: msg
  defp prefix_message(msg), do: @runtime_prefix <> msg

  defp extract_context(error) when is_struct(error) do
    {Map.get(error, :line), Map.get(error, :source), Map.get(error, :call_stack)}
  end

  defp extract_context(_), do: {nil, nil, nil}

  # Classify a wrapped VM exception into its user-facing category. Arbitrary
  # Elixir exceptions (no Lua-side value) return `nil`.
  defp kind(%Lua.VM.RuntimeError{}), do: :error
  defp kind(%Lua.VM.TypeError{}), do: :type
  defp kind(%Lua.VM.ArgumentError{}), do: :argument
  defp kind(%Lua.VM.AssertionError{}), do: :assertion
  defp kind(%Lua.VM.InternalError{}), do: :internal
  defp kind(_), do: nil

  defp format_function([], function), do: "#{function}()"

  defp format_function(scope, function) do
    "#{Enum.join(scope, ".")}.#{function}()"
  end
end
