defmodule Lua.VM.Stdlib do
  @moduledoc """
  Standard library functions for the Lua VM.

  Provides essential built-in functions that are available in the global
  scope when the standard library is installed.
  """

  alias Lua.VM.ArgumentError
  alias Lua.VM.AssertionError
  alias Lua.VM.Executor
  alias Lua.VM.Limits
  alias Lua.VM.ProtectedCall
  alias Lua.VM.RuntimeError
  alias Lua.VM.State
  alias Lua.VM.Table
  alias Lua.VM.TypeError
  alias Lua.VM.Value

  @doc """
  Installs the standard library into the given VM state.
  """
  @spec install(State.t()) :: State.t()
  def install(%State{} = state) do
    state
    |> State.register_function("type", &lua_type/2)
    |> State.register_function("tostring", &lua_tostring/2)
    |> State.register_function("tonumber", &lua_tonumber/2)
    |> State.register_function("print", &lua_print/2)
    |> State.register_function("error", &lua_error/2)
    |> State.register_function("assert", &lua_assert/2)
    |> State.register_function("pcall", &lua_pcall/2)
    |> State.register_function("xpcall", &lua_xpcall/2)
    |> State.register_function("rawget", &lua_rawget/2)
    |> State.register_function("rawset", &lua_rawset/2)
    |> State.register_function("rawlen", &lua_rawlen/2)
    |> State.register_function("rawequal", &lua_rawequal/2)
    |> State.register_function("next", &lua_next/2)
    |> State.register_function("pairs", &lua_pairs/2)
    |> State.register_function("ipairs", &lua_ipairs/2)
    |> State.register_function("setmetatable", &lua_setmetatable/2)
    |> State.register_function("getmetatable", &lua_getmetatable/2)
    |> State.register_function("select", &lua_select/2)
    |> State.register_function("load", &lua_load/2)
    |> State.register_function("require", &lua_require/2)
    |> State.register_function("collectgarbage", &lua_collectgarbage/2)
    |> State.register_function("dofile", &lua_dofile/2)
    |> State.set_global("_VERSION", "Lua 5.3")
    |> install_package_table()
    |> install_library(Lua.VM.Stdlib.String)
    |> install_library(Lua.VM.Stdlib.Math)
    |> install_library(Lua.VM.Stdlib.Table)
    |> install_library(Lua.VM.Stdlib.Utf8)
    |> install_library(Lua.VM.Stdlib.Os)
    |> install_library(Lua.VM.Stdlib.Debug)
    |> preload_stdlib_modules()
    |> install_unpack_alias()
    |> install_global_g()
  end

  # Install a stdlib library module and register it in package.loaded
  defp install_library(state, module) do
    state = module.install(state)
    name = module.lib_name()

    case State.get_global(state, name) do
      {:tref, _} = tref -> cache_module_result(state, name, tref)
      _ -> state
    end
  end

  # Install `_G` and `_ENV` globals.
  #
  # As of Plan A16 (Lua 5.3 `_ENV` semantics), the `_G` table itself is the
  # storage for globals — its `data` map is what `State.set_global/3` and
  # `State.get_global/2` read and write. The `_G` table is allocated by
  # `State.new/0` and its tref is stored in `state.g_ref`.
  #
  # Here we just expose `_G` to Lua code under the names `_G` and `_ENV`.
  # Top-level chunks see `_ENV` as a register holding `_G`; user code can
  # reassign `_ENV` to redirect global access without affecting `_G` itself.
  defp install_global_g(state) do
    g_ref = State.g_ref(state)

    # Expose _G to Lua under the name "_G"
    state = State.set_global(state, "_G", g_ref)

    # _ENV is also exposed at boot for backwards compatibility with code that
    # references `_ENV` as a global. The compiler binds `_ENV` as a chunk-level
    # local (register 0) at execute time, so this global is mostly for
    # introspection; user-level `_ENV` reassignment goes to that local, not
    # this global.
    State.set_global(state, "_ENV", g_ref)
  end

  # Pre-load any stdlib table globals into package.loaded so that
  # require("string"), require("math"), etc. resolve to the existing global
  # tables without triggering a filesystem search. This mirrors Lua 5.3's
  # behaviour where package.loaded is pre-populated by the runtime.
  #
  # install_library/2 already caches the four installed modules (string, math,
  # table, debug), so this pass is a safety net for any future stdlib tables
  # that may be added as globals before this call.
  defp preload_stdlib_modules(state) do
    modules = ["string", "math", "table", "utf8", "debug"]

    Enum.reduce(modules, state, fn name, acc ->
      case State.get_global(acc, name) do
        {:tref, _} = tref -> cache_module_result(acc, name, tref)
        _ -> acc
      end
    end)
  end

  # type(v) — returns the type of v as a string
  defp lua_type([value | _], state), do: {[Value.type_name(value)], state}
  defp lua_type([], _state), do: raise(ArgumentError.value_expected("type", 1))

  # tostring(v) — converts a value to its string representation
  defp lua_tostring([value | _], state) do
    {str, state} = value_to_string_with_mt(value, state)
    {[str], state}
  end

  defp lua_tostring([], state), do: {["nil"], state}

  # tonumber(v [, base]) — converts a string to a number
  defp lua_tonumber([value | rest], state) do
    base = List.first(rest)

    result =
      case {value, base} do
        {v, nil} when is_number(v) ->
          v

        {v, nil} when is_binary(v) ->
          Value.parse_number(v)

        {v, b} when is_binary(v) and is_integer(b) and b >= 2 and b <= 36 ->
          case Integer.parse(v, b) do
            {n, ""} -> n
            _ -> nil
          end

        _ ->
          nil
      end

    {[result], state}
  end

  defp lua_tonumber([], state), do: {[nil], state}

  # print(...) — prints values separated by tabs, followed by a newline
  defp lua_print(args, state) do
    {strings, state} =
      Enum.reduce(args, {[], state}, fn val, {acc, st} ->
        {str, st} = value_to_string_with_mt(val, st)
        {[str | acc], st}
      end)

    output = strings |> Enum.reverse() |> Enum.join("\t")
    IO.puts(output)
    {[], state}
  end

  # error(message [, level]) — raises a Lua runtime error.
  # The executor stashes the calling source position in the process dict
  # before invoking native callbacks (see `Lua.VM.Executor.execute/5`), so
  # this raise picks up `at <source>:<line>:` automatically. If the function
  # is called outside a Lua execution (or from a context where no line was
  # set), `current_position/0` returns `{nil, nil}` and the message just
  # omits the location.
  #
  # Per Lua 5.3 §6.1 the raised value passes through pcall/xpcall verbatim,
  # and string messages gain a `source:line:` prefix unless `level == 0`.
  # The prefixed view lives in `:lua_value` (Lua-facing only); `:value`
  # stays raw so host rendering is untouched. Levels >= 2 (attribute to the
  # caller's caller) need per-frame lines the call stack does not carry and
  # are treated as level 1 for now.
  defp lua_error([message | rest], state) do
    {line, source} = Executor.current_position()
    level = error_level(rest)

    raise RuntimeError,
      value: message,
      lua_value: position_prefixed(message, level, line, source),
      line: line,
      source: source,
      state: state
  end

  defp lua_error([], state) do
    {line, source} = Executor.current_position()
    raise RuntimeError, value: nil, line: line, source: source, state: state
  end

  defp error_level([level | _]) when is_number(level), do: level
  defp error_level(_), do: 1

  # §6.1 position prefix: only string messages, only when `level ~= 0`, and
  # only when the executor recorded a usable position. A `{nil, _}` position
  # (native call inside a compiled closure — the dispatcher does not plumb
  # per-call lines yet) omits the prefix rather than emit a wrong line.
  defp position_prefixed(message, level, line, source)
       when is_binary(message) and level != 0 and is_integer(line) and is_binary(source) do
    "#{source}:#{line}: #{message}"
  end

  defp position_prefixed(message, _level, _line, _source), do: message

  # assert(v [, message]) — raises if v is falsy
  defp lua_assert([value | rest], state) do
    if value == nil or value == false do
      message =
        case rest do
          [msg | _] -> msg
          [] -> "assertion failed!"
        end

      {line, source} = Executor.current_position()
      raise AssertionError, value: message, line: line, source: source, state: state
    else
      {[value | rest], state}
    end
  end

  defp lua_assert([], state) do
    {line, source} = Executor.current_position()
    raise AssertionError, value: "assertion failed!", line: line, source: source, state: state
  end

  # pcall(f [, arg1, ...]) — calls function in protected mode
  # Returns true, result(s) on success or false, error_message on error.
  # The trapped error unwinds control state only: heap effects the callee
  # made before raising are kept via the exception's `:state` snapshot
  # (Lua 5.3 §2.3) — see `State.unwind_to/2`.
  defp lua_pcall([func | args], state) do
    {results, state} = Executor.call_function(func, args, state)
    {[true | results], state}
  rescue
    e in [RuntimeError, AssertionError, TypeError, ArgumentError] ->
      {[false, ProtectedCall.error_value(e)], State.unwind_to(state, e.state)}

    e ->
      # Catch any other error
      {[false, Exception.message(e)], State.unwind_to(state, raised_state(e))}
  end

  defp lua_pcall([], state), do: {[false, "bad argument #1 to 'pcall' (value expected)"], state}

  # xpcall(f, msgh [, arg1, ...]) — calls function with message handler
  # Returns true, result(s) on success or false, handler_result on error.
  # Like pcall, heap effects made before the error are kept; the message
  # handler runs against that recovered state so it observes them
  # (reference Lua invokes the handler before the stack unwinds, with the
  # heap intact).
  defp lua_xpcall([func, handler | args], state) do
    {results, state} = Executor.call_function(func, args, state)
    {[true | results], state}
  rescue
    e in [RuntimeError, AssertionError, TypeError, ArgumentError] ->
      run_xpcall_handler(handler, ProtectedCall.error_value(e), State.unwind_to(state, e.state))

    e ->
      # Catch any other error
      run_xpcall_handler(handler, Exception.message(e), State.unwind_to(state, raised_state(e)))
  end

  defp lua_xpcall(_, state), do: {[false, "bad argument to 'xpcall'"], state}

  # If the handler itself fails, return the original error — keeping any
  # heap effects the handler made before its own error.
  defp run_xpcall_handler(handler, error_msg, state) do
    {handler_results, state} = Executor.call_function(handler, [error_msg], state)
    {[false | handler_results], state}
  rescue
    e ->
      {[false, error_msg], State.unwind_to(state, raised_state(e))}
  end

  # Raise-time state ferried out on VM exceptions; `nil` for anything else
  # (plain Elixir exceptions carry no Lua state).
  defp raised_state(%{state: %State{} = state}), do: state
  defp raised_state(_), do: nil

  # rawget(table, key) — get without metamethods
  defp lua_rawget([{:tref, id}, key | _], state) do
    table = Map.fetch!(state.tables, id)
    {[Table.get(table, key)], state}
  end

  # rawset(table, key, value) — set without metamethods
  defp lua_rawset([{:tref, _} = tref, key, value | _], state) do
    state = State.update_table(state, tref, fn table -> Table.put(table, key, value) end)
    {[tref], state}
  end

  # rawlen(v) — length without metamethods.
  #
  # Lua 5.3 reference: rawlen requires a table or string argument and
  # raises "table or string expected" otherwise. The previous
  # implementation silently returned 0 for non-table, non-string
  # values, which broke `pcall(rawlen, ...)` patterns in events.lua.
  defp lua_rawlen([{:tref, id} | _], state) do
    table = Map.fetch!(state.tables, id)
    {[Table.length(table)], state}
  end

  defp lua_rawlen([v | _], state) when is_binary(v) do
    {[byte_size(v)], state}
  end

  defp lua_rawlen([], _state) do
    raise ArgumentError.value_expected("rawlen", 1)
  end

  defp lua_rawlen([v | _], _state) do
    raise ArgumentError,
      function_name: "rawlen",
      arg_num: 1,
      expected: "table or string",
      got: Value.type_name(v)
  end

  # rawequal(a, b) — equality without metamethods
  defp lua_rawequal([a, b | _], state) do
    {[a === b], state}
  end

  defp lua_rawequal(_, state), do: {[false], state}

  # next(table [, key]) — returns next key-value pair after key.
  # Per Lua 5.3 §6.1, when `key` is non-nil and was never a key in the
  # table, raises "invalid key to 'next'". Dead keys (cleared during
  # iteration) are treated as still-iterable so `for k,v in pairs(t)`
  # loops that nil out their keys mid-traversal complete cleanly.
  defp lua_next([{:tref, id} | rest], state) do
    key = List.first(rest)
    table = Map.fetch!(state.tables, id)

    # Eagerly flush any deferred-append `order_tail` and build the O(1)
    # iteration memo so subsequent steps are index lookups rather than
    # linear scans. The first call to `lua_next` for a given iteration
    # pays the cost once; the rest see a clean `order` and a live memo.
    {table, state} =
      if table.order_tail == [] and table.order_index != nil do
        {table, state}
      else
        flushed = Table.flush_order(table)
        {flushed, %{state | tables: Map.put(state.tables, id, flushed)}}
      end

    case Table.next_entry(table, key) do
      :invalid_key ->
        raise ArgumentError,
          function_name: "next",
          arg_num: 2,
          details: "invalid key to 'next'",
          state: state

      nil ->
        {[nil, nil], state}

      {k, v} ->
        {[k, v], state}
    end
  end

  defp lua_next(_, state), do: {[nil, nil], state}

  # pairs(table) — returns next, table, nil
  defp lua_pairs([{:tref, _} = tref | _], state) do
    next_func = State.get_global(state, "next")
    {[next_func, tref, nil], state}
  end

  defp lua_pairs([], _state), do: raise(ArgumentError.value_expected("pairs", 1))

  defp lua_pairs([v | _], _state), do: raise(ArgumentError.type_error("pairs", 1, "table", Value.type_name(v)))

  # ipairs(table) — returns iterator function, table, 0
  defp lua_ipairs([{:tref, _} = tref | _], state) do
    # Per Lua 5.3 §6.1, ipairs reads through the indexing operator, so
    # __index is honoured. Iteration stops at the first nil.
    iterator =
      {:native_func,
       fn [table_ref, index], state ->
         i = index + 1

         case Executor.table_index(table_ref, i, state) do
           {nil, state} -> {[nil], state}
           {v, state} -> {[i, v], state}
         end
       end}

    {[iterator, tref, 0], state}
  end

  defp lua_ipairs([], _state), do: raise(ArgumentError.value_expected("ipairs", 1))

  defp lua_ipairs([v | _], _state), do: raise(ArgumentError.type_error("ipairs", 1, "table", Value.type_name(v)))

  # select(index, ...) — returns arguments starting from index
  # select('#', ...) — returns count of arguments
  defp lua_select(["#" | args], state) do
    {[length(args)], state}
  end

  defp lua_select([index | args], state) when is_integer(index) do
    cond do
      # Positive index: return from that position onward
      index > 0 ->
        selected = Enum.drop(args, index - 1)
        {selected, state}

      # Negative index: count from end (take last n elements)
      index < 0 ->
        selected = Enum.take(args, index)
        {selected, state}

      # Index 0 is invalid
      true ->
        raise RuntimeError, value: "bad argument #1 to 'select' (index out of range)"
    end
  end

  defp lua_select([non_valid | _], _state) do
    raise ArgumentError,
      function_name: "select",
      arg_num: 1,
      expected: "number or '#'",
      got: Value.type_name(non_valid)
  end

  defp lua_select([], _state) do
    raise ArgumentError.value_expected("select", 1)
  end

  # load(chunk, chunkname, mode, env) — loads a Lua chunk
  # `chunk` may be either a string or a reader function. A reader function
  # is called repeatedly; each call must return a string piece, and the
  # chunk ends when it returns nil, an empty string, or no value.
  # Returns the compiled function, or (nil, error message) on failure.
  defp lua_load([chunk | rest], state) when is_binary(chunk) do
    compile_loaded_chunk(chunk, load_env_arg(rest, state), state)
  end

  defp lua_load([{:lua_closure, _, _} = reader | rest], state) do
    load_from_reader(reader, load_env_arg(rest, state), state)
  end

  defp lua_load([{:compiled_closure, _, _} = reader | rest], state) do
    load_from_reader(reader, load_env_arg(rest, state), state)
  end

  defp lua_load([{:native_func, _} = reader | rest], state) do
    load_from_reader(reader, load_env_arg(rest, state), state)
  end

  defp lua_load([_other | _], state) do
    # Lua 5.3 reference: "If chunk is not a string, load also accepts a
    # function value." Anything else is rejected.
    {[nil, "bad argument #1 to 'load' (string or function expected)"], state}
  end

  defp lua_load([], _state) do
    raise ArgumentError.value_expected("load", 1)
  end

  # Calls the reader function in a loop, accumulating string pieces until
  # it signals end-of-chunk (nil or ""). Bails out with `(nil, error_msg)`
  # if the reader ever returns a non-string non-nil value, mirroring the
  # behavior of Lua 5.3's reference implementation.
  defp load_from_reader(reader, env, state) do
    case collect_reader_chunks(reader, state, [], 0) do
      {:ok, source, state} ->
        compile_loaded_chunk(source, env, state)

      {:error, msg, state} ->
        {[nil, msg], state}
    end
  end

  # The optional 4th argument to `load(chunk, chunkname, mode, env)` is the
  # environment the loaded chunk sees as `_ENV`. When absent or nil it defaults
  # to the current global table `_G` (Lua 5.3 §6.1).
  defp load_env_arg([_chunkname, _mode, env | _], _state) when env != nil, do: env
  defp load_env_arg(_rest, state), do: State.g_ref(state)

  defp collect_reader_chunks(reader, state, acc, size) do
    {results, state} = Executor.call_function(reader, [], state)

    case results do
      [] ->
        {:ok, IO.iodata_to_binary(Enum.reverse(acc)), state}

      [nil | _] ->
        {:ok, IO.iodata_to_binary(Enum.reverse(acc)), state}

      ["" | _] ->
        {:ok, IO.iodata_to_binary(Enum.reverse(acc)), state}

      [piece | _] when is_binary(piece) ->
        # A reader that never signals end-of-input would otherwise accumulate
        # chunks until the host runs out of memory. Bound the total source
        # size with the same ceiling used for string allocations. Note this
        # raises rather than returning load's documented `(nil, message)`
        # pair: an oversized reader is a DoS attempt, not a recoverable
        # syntax error, so we surface it as a catchable runtime error
        # (caught by `pcall`) instead of a quiet load failure.
        Limits.check_string_size!(size + byte_size(piece), state.max_string_bytes)
        collect_reader_chunks(reader, state, [piece | acc], size + byte_size(piece))

      [bad | _] ->
        {:error, "reader function must return a string (got #{Value.type_name(bad)})", state}
    end
  end

  defp compile_loaded_chunk(source, env, state) do
    case Lua.Parser.parse(source) do
      {:ok, ast} ->
        # Compiler currently never returns errors, always succeeds — see
        # `Lua.Compiler.compile!/2` for the matching note.
        {:ok, prototype} = Lua.Compiler.compile(ast)

        # A loaded chunk's sole upvalue is `_ENV`. Back it with a real cell
        # holding `env` so `load_env` sources it (instead of `_G`), the chunk's
        # global writes route through `env`, and `debug.getupvalue`/`setupvalue`
        # can read and mutate it.
        env_cell = make_ref()
        state = %{state | upvalue_cells: Map.put(state.upvalue_cells, env_cell, env)}

        # When the bytecode compiler accepts the loaded chunk, surface
        # it as a `:compiled_closure` so the dispatcher takes over.
        # Otherwise fall back to the standard interpreted closure.
        closure =
          case prototype.bytecode do
            nil -> {:lua_closure, prototype, {env_cell}}
            _ -> {:compiled_closure, prototype, {env_cell}}
          end

        {[closure], state}

      {:error, reason} ->
        error_msg = format_parse_error(reason)
        {[nil, error_msg], state}
    end
  end

  defp format_parse_error(error) when is_binary(error), do: error

  # setmetatable(table, metatable) — sets the metatable for a table
  defp lua_setmetatable([{:tref, _} = tref, metatable], state) do
    # Check for __metatable protection on existing metatable
    table = State.get_table(state, tref)

    case table.metatable do
      {:tref, mt_id} ->
        mt = Map.fetch!(state.tables, mt_id)

        if Map.has_key?(mt.data, "__metatable") do
          raise RuntimeError, value: "cannot change a protected metatable"
        end

      _ ->
        :ok
    end

    # Validate metatable is nil or a table
    case metatable do
      nil ->
        state = State.update_table(state, tref, fn table -> %{table | metatable: nil} end)
        {[tref], state}

      {:tref, _} = mt_ref ->
        state = State.update_table(state, tref, fn table -> %{table | metatable: mt_ref} end)
        {[tref], state}

      _ ->
        raise ArgumentError,
          function_name: "setmetatable",
          arg_num: 2,
          expected: "nil or table"
    end
  end

  defp lua_setmetatable([non_table | _], _state) do
    raise ArgumentError,
      function_name: "setmetatable",
      arg_num: 1,
      expected: "table",
      got: Value.type_name(non_table)
  end

  defp lua_setmetatable([], _state) do
    raise ArgumentError.value_expected("setmetatable", 1)
  end

  # getmetatable(object) — returns the metatable of an object
  defp lua_getmetatable([{:tref, _} = tref | _], state) do
    table = State.get_table(state, tref)

    case table.metatable do
      nil ->
        {[nil], state}

      {:tref, mt_id} = mt_ref ->
        mt = Map.fetch!(state.tables, mt_id)

        # If metatable has __metatable field, return that instead
        case Map.get(mt.data, "__metatable") do
          nil -> {[mt_ref], state}
          sentinel -> {[sentinel], state}
        end
    end
  end

  defp lua_getmetatable([value | _], state) when is_binary(value) do
    # For strings, return the string metatable if set
    case Map.get(state.metatables, "string") do
      nil -> {[nil], state}
      mt_ref -> {[mt_ref], state}
    end
  end

  defp lua_getmetatable([_other | _], state) do
    {[nil], state}
  end

  defp lua_getmetatable([], state) do
    {[nil], state}
  end

  # Install package table with loaded and path fields
  defp install_package_table(state) do
    # Create package.loaded table (initially empty)
    {loaded_tref, state} = State.alloc_table(state)

    # Create package.preload table (initially empty)
    {preload_tref, state} = State.alloc_table(state)

    # Create package table with loaded, preload, and path fields
    package_data = %{
      "loaded" => loaded_tref,
      "preload" => preload_tref,
      "path" => "?.lua;?/init.lua"
    }

    {package_tref, state} = State.alloc_table(state, package_data)

    state = State.set_global(state, "package", package_tref)

    # Cache "package" itself in package.loaded
    cache_module_result(state, "package", package_tref)
  end

  # require(modname) — loads a Lua module
  defp lua_require([modname | _], state) when is_binary(modname) do
    # Get package table
    {:tref, pkg_id} = State.get_global(state, "package")
    package = Map.fetch!(state.tables, pkg_id)

    # Get package.loaded table
    {:tref, loaded_id} = Map.fetch!(package.data, "loaded")
    loaded_table = Map.fetch!(state.tables, loaded_id)

    # Check if already loaded
    case Map.get(loaded_table.data, modname) do
      nil ->
        # Not loaded. First consult package.preload, then fall back to path.
        case lookup_preload(modname, package, state) do
          {:ok, loader} ->
            load_from_preload(modname, loader, state)

          :not_found ->
            search_path = Map.get(package.data, "path", "?.lua")
            load_module(modname, search_path, state)
        end

      result ->
        # Already loaded, return cached result
        {[result], state}
    end
  end

  defp lua_require([non_string | _], _state) do
    raise ArgumentError,
      function_name: "require",
      arg_num: 1,
      expected: "string",
      got: Value.type_name(non_string)
  end

  defp lua_require([], _state) do
    raise ArgumentError.value_expected("require", 1)
  end

  # Look up `package.preload[modname]`. Returns `{:ok, loader}` if a callable
  # is registered, `:not_found` otherwise. This is the narrow searcher
  # equivalent for `package.preload` — we don't yet expose the full
  # `package.searchers` table.
  defp lookup_preload(modname, package, state) do
    case Map.get(package.data, "preload") do
      {:tref, preload_id} ->
        preload_table = Map.fetch!(state.tables, preload_id)

        case Map.get(preload_table.data, modname) do
          nil -> :not_found
          loader -> {:ok, loader}
        end

      _ ->
        :not_found
    end
  end

  # Call a preload loader (closure or native_func) with the module name
  # and cache its result, mirroring `parse_and_execute_module`.
  defp load_from_preload(modname, loader, state) do
    state = cache_module_result(state, modname, true)
    {results, state} = Executor.call_function(loader, [modname], state)

    result =
      case results do
        [value | _] -> value
        [] -> true
      end

    state = cache_module_result(state, modname, result)
    {[result], state}
  end

  # Load a module by searching the path
  defp load_module(modname, search_path, state) do
    patterns = String.split(search_path, ";", trim: true)

    case find_module_file(modname, patterns) do
      {:ok, file_path, content} ->
        parse_and_execute_module(modname, file_path, content, state)

      {:error, :not_found} ->
        raise RuntimeError,
          value: "module '#{modname}' not found:\n\tno file '#{search_path}'"
    end
  end

  # Parse, compile, and execute a module file.
  #
  # Caches `true` as a sentinel in `package.loaded` *before* executing the
  # module body so that any recursive `require(modname)` call from within
  # the body resolves to the sentinel instead of triggering another
  # filesystem search and re-execution. This mirrors reference Lua's
  # behavior and prevents infinite recursion when a module file's name
  # collides with a package on the search path (e.g. a test file named
  # `utf8.lua` calling `require'utf8'`).
  #
  # The sentinel is overwritten with the module's actual return value (or
  # `true` if the module returned nothing) once execution completes.
  defp parse_and_execute_module(modname, file_path, content, state) do
    state = cache_module_result(state, modname, true)

    with {:ok, ast} <- Lua.Parser.parse(content),
         {:ok, proto} <- Lua.Compiler.compile(ast),
         # `require` runs mid-evaluation: inherit the caller's instruction
         # budget instead of resetting it, so a looping module body counts
         # against the same `:max_steps` and the pre-require work is preserved.
         {:ok, results, state} <- Lua.VM.execute(proto, state, reset_steps: false) do
      # Get the return value (or true if no return value)
      result =
        case results do
          [value | _] -> value
          [] -> true
        end

      # Overwrite the sentinel with the actual result
      state = cache_module_result(state, modname, result)
      {[result], state}
    else
      {:error, msg} ->
        raise RuntimeError,
          value: "error loading module '#{modname}' from file '#{file_path}':\n#{msg}"
    end
  end

  # Cache the module result in package.loaded
  defp cache_module_result(state, modname, result) do
    {:tref, loaded_id} = get_package_loaded_ref(state)

    State.update_table(state, {:tref, loaded_id}, fn loaded_table ->
      Table.put(loaded_table, modname, result)
    end)
  end

  # Get the package.loaded table reference
  defp get_package_loaded_ref(state) do
    with {:tref, pkg_id} <- State.get_global(state, "package"),
         package = Map.fetch!(state.tables, pkg_id),
         {:tref, _loaded_id} = loaded_ref <- Map.fetch!(package.data, "loaded") do
      loaded_ref
    end
  end

  # Find a module file by searching the patterns
  defp find_module_file(modname, patterns) do
    resolved = String.replace(modname, ".", "/")

    Enum.find_value(patterns, {:error, :not_found}, fn pattern ->
      file_path = String.replace(pattern, "?", resolved)

      case File.read(file_path) do
        {:ok, content} -> {:ok, file_path, content}
        {:error, _} -> nil
      end
    end)
  end

  # Convert a value to string, checking for __tostring metamethod
  defp value_to_string_with_mt(value, state) do
    case value do
      {:tref, id} ->
        table = Map.fetch!(state.tables, id)

        case table.metatable do
          {:tref, mt_id} ->
            mt = Map.fetch!(state.tables, mt_id)

            case Map.get(mt.data, "__tostring") do
              nil ->
                {Value.to_string(value), state}

              tostring_fn ->
                {results, state} = Executor.call_function(tostring_fn, [value], state)
                {List.first(results) || "nil", state}
            end

          _ ->
            {Value.to_string(value), state}
        end

      _ ->
        {Value.to_string(value), state}
    end
  end

  # collectgarbage stub — no-op accepting all standard modes
  defp lua_collectgarbage(args, state) do
    mode = List.first(args) || "collect"

    case mode do
      "count" ->
        # Return plausible memory usage in KB and remainder bytes
        {[0.0, 0], state}

      "isrunning" ->
        {[true], state}

      _ ->
        # "collect", "stop", "restart", "step", "setpause", "setstepmul", "generational", "incremental"
        {[0], state}
    end
  end

  # dofile stub — not supported in embedded mode
  defp lua_dofile(_args, _state) do
    raise RuntimeError, value: "dofile not supported in embedded mode"
  end

  # Install global 'unpack' as alias for table.unpack
  defp install_unpack_alias(state) do
    case State.get_global(state, "table") do
      {:tref, id} ->
        table = Map.fetch!(state.tables, id)

        case Map.get(table.data, "unpack") do
          nil -> state
          unpack_fn -> State.set_global(state, "unpack", unpack_fn)
        end

      _ ->
        state
    end
  end
end
