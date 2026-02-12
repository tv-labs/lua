defmodule Lua.VM.Stdlib.Debug do
  @moduledoc """
  Lua 5.3 debug standard library.

  Provides introspection and debugging facilities. Many functions are stubs
  that return plausible values since full debug support is not needed for
  most embedded use cases.

  ## Functions

  - `debug.getinfo(f [, what])` - Returns info about a function
  - `debug.traceback([message [, level]])` - Returns a traceback string
  - `debug.getmetatable(obj)` - Returns metatable bypassing __metatable
  - `debug.setmetatable(obj, mt)` - Sets metatable bypassing __metatable
  - `debug.getlocal(level, local)` - Stub returning nil
  - `debug.setlocal(level, local, value)` - Stub returning nil
  - `debug.sethook([hook, mask [, count]])` - Stub no-op
  - `debug.gethook([thread])` - Stub returning nil
  - `debug.getupvalue(f, up)` - Stub returning nil
  - `debug.setupvalue(f, up, value)` - Stub returning nil
  - `debug.upvalueid(f, n)` - Stub returning nil
  """

  @behaviour Lua.VM.Stdlib.Library

  alias Lua.VM.State
  alias Lua.VM.Value

  @impl true
  def lib_name, do: "debug"

  @impl true
  def install(state) do
    debug_table = %{
      "getinfo" => {:native_func, &debug_getinfo/2},
      "traceback" => {:native_func, &debug_traceback/2},
      "getmetatable" => {:native_func, &debug_getmetatable/2},
      "setmetatable" => {:native_func, &debug_setmetatable/2},
      "getlocal" => {:native_func, &debug_getlocal/2},
      "setlocal" => {:native_func, &debug_setlocal/2},
      "sethook" => {:native_func, &debug_sethook/2},
      "gethook" => {:native_func, &debug_gethook/2},
      "getupvalue" => {:native_func, &debug_getupvalue/2},
      "setupvalue" => {:native_func, &debug_setupvalue/2},
      "upvalueid" => {:native_func, &debug_upvalueid/2}
    }

    {tref, state} = State.alloc_table(state, debug_table)
    State.set_global(state, "debug", tref)
  end

  # debug.getinfo(f [, what]) — returns table with function info
  defp debug_getinfo([func | rest], state) do
    _what = List.first(rest) || "flnStu"

    info =
      case func do
        {:lua_closure, proto, _upvalues} ->
          %{
            "source" => Map.get(proto, :source, "=?"),
            "currentline" => -1,
            "what" => "Lua",
            "name" => nil,
            "linedefined" => Map.get(proto, :line_defined, 0),
            "lastlinedefined" => Map.get(proto, :last_line_defined, 0),
            "nparams" => Map.get(proto, :param_count, 0),
            "isvararg" => if(Map.get(proto, :is_vararg, false), do: true, else: false)
          }

        {:native_func, _} ->
          %{
            "source" => "=[C]",
            "currentline" => -1,
            "what" => "C",
            "name" => nil
          }

        n when is_integer(n) ->
          # Stack level - return info about calling function
          %{
            "source" => "=?",
            "currentline" => -1,
            "what" => "main",
            "name" => nil
          }

        _ ->
          %{
            "source" => "=?",
            "currentline" => -1,
            "what" => "main",
            "name" => nil
          }
      end

    {info_tref, state} = State.alloc_table(state, info)
    {[info_tref], state}
  end

  defp debug_getinfo([], state) do
    {info_tref, state} =
      State.alloc_table(state, %{
        "source" => "=?",
        "currentline" => -1,
        "what" => "main",
        "name" => nil
      })

    {[info_tref], state}
  end

  # debug.traceback([message [, level]]) — returns traceback string
  defp debug_traceback(args, state) do
    message = List.first(args)
    _level = Enum.at(args, 1, 1)

    traceback =
      state.call_stack
      |> Enum.with_index(1)
      |> Enum.map(fn {frame, _i} ->
        source = Map.get(frame, :source, "?")
        line = Map.get(frame, :line, 0)
        "\t#{source}:#{line}: in ?"
      end)

    header = "stack traceback:"
    body = Enum.join([header | traceback], "\n")

    result =
      if message do
        "#{Value.to_string(message)}\n#{body}"
      else
        body
      end

    {[result], state}
  end

  # debug.getmetatable(obj) — returns metatable bypassing __metatable protection
  defp debug_getmetatable([{:tref, _} = tref | _], state) do
    table = State.get_table(state, tref)

    case table.metatable do
      nil -> {[nil], state}
      mt_ref -> {[mt_ref], state}
    end
  end

  defp debug_getmetatable([value | _], state) when is_binary(value) do
    case Map.get(state.metatables, "string") do
      nil -> {[nil], state}
      mt_ref -> {[mt_ref], state}
    end
  end

  defp debug_getmetatable([_ | _], state), do: {[nil], state}
  defp debug_getmetatable([], state), do: {[nil], state}

  # debug.setmetatable(obj, mt) — sets metatable bypassing __metatable protection
  defp debug_setmetatable([{:tref, _} = tref, mt | _], state) do
    mt_ref =
      case mt do
        nil -> nil
        {:tref, _} = ref -> ref
        _ -> nil
      end

    state =
      State.update_table(state, tref, fn table ->
        %{table | metatable: mt_ref}
      end)

    {[tref], state}
  end

  defp debug_setmetatable([obj | _], state), do: {[obj], state}
  defp debug_setmetatable([], state), do: {[nil], state}

  # Stubs
  defp debug_getlocal(_args, state), do: {[nil], state}
  defp debug_setlocal(_args, state), do: {[nil], state}
  defp debug_sethook(_args, state), do: {[], state}
  defp debug_gethook(_args, state), do: {[nil, "", 0], state}
  defp debug_getupvalue(_args, state), do: {[nil], state}
  defp debug_setupvalue(_args, state), do: {[nil], state}
  defp debug_upvalueid(_args, state), do: {[nil], state}
end
