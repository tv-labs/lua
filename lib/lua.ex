defmodule Lua do
  @external_resource "README.md"
  @moduledoc @external_resource
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  @type t :: %__MODULE__{}

  defstruct [:state]

  alias Lua.Util

  @default_sandbox [
    [:io],
    [:file],
    [:os, :execute],
    [:os, :exit],
    [:os, :getenv],
    [:os, :remove],
    [:os, :rename],
    [:os, :tmpname],
    [:package],
    [:load],
    [:loadfile],
    [:require],
    [:dofile],
    [:load],
    [:loadfile],
    [:loadstring]
  ]

  defimpl Inspect do
    def inspect(_lua, _opts) do
      "#Lua<>"
    end
  end

  @doc """
  Initializes a Lua VM sandbox

      iex> Lua.new()

  By default, the following Lua functions are sandboxed.

  #{Enum.map_join(@default_sandbox, "\n", fn func -> "* `#{inspect(func)}`" end)}

  To disable, use the `sandboxed` option, passing an empty list

      iex> Lua.new(sandboxed: [])

  Alternatively, you can pass your own list of functions to sandbox. This is equivalent to calling
  `Lua.sandbox/2`.

      iex> Lua.new(sandboxed: [[:os, :exit]])


  ## Options
  * `:sandboxed` - list of paths to be sandboxed, e.g. `sandboxed: [[:require], [:os, :exit]]`
  * `:exclude` - list of paths to exclude from the sandbox, e.g. `exclude: [[:require], [:package]]`
  """
  def new(opts \\ []) do
    opts = Keyword.validate!(opts, sandboxed: @default_sandbox, exclude: [])
    exclude = Keyword.fetch!(opts, :exclude)

    opts
    |> Keyword.fetch!(:sandboxed)
    |> Enum.reject(fn path -> path in exclude end)
    |> Enum.reduce(%__MODULE__{state: :luerl.init()}, &sandbox(&2, &1))
  end

  @doc """
  Write Lua code that is parsed at compile-time.

      iex> ~LUA"return 2 + 2"
      "return 2 + 2"

  If the code cannot be lexed and parsed, it raises a `Lua.CompilerException`

      #iex> ~LUA":not_lua"
      ** (Lua.CompilerException) Failed to compile Lua!

  As an optimization, the `c` modifier can be used to return a pre-compiled Lua chunk

      iex> ~LUA"return 2 + 2"c
  """
  defmacro sigil_LUA(code, opts) do
    code =
      case code do
        {:<<>>, _, [literal]} -> literal
        _ -> raise "~Lua only accepts string literals, received:\n\n#{Macro.to_string(code)}"
      end

    chunk =
      case :luerl_comp.string(code, [:return]) do
        {:ok, chunk} -> %Lua.Chunk{instructions: chunk}
        {:error, error, _warnings} -> raise Lua.CompilerException, error
      end

    case opts do
      [?c] -> Macro.escape(chunk)
      _ -> code
    end
  end

  @doc """
  Sandboxes the given path, swapping out the implementation with
  a function that raises when called

      iex> lua = Lua.new(sandboxed: [])
      iex> Lua.sandbox(lua, [:os, :exit])

  """
  def sandbox(lua, path) do
    set!(lua, [:_G | path], fn args ->
      raise Lua.RuntimeException,
            "#{Lua.Util.format_function(path, Enum.count(args))} is sandboxed"
    end)
  end

  @doc """
  Sets the path patterns that Luerl will look in when requiring Lua scripts. For example,
  if you store Lua files in your application's priv directory:

      iex> lua = Lua.new(exclude: [[:package], [:require]])
      iex> Lua.set_lua_paths(lua, ["myapp/priv/lua/?.lua", "myapp/lua/?/init.lua"])

  Now you can use the [Lua require](https://www.lua.org/pil/8.1.html) function to import
  these scripts

  > #### Warning {: .warning}
  > In order to use `Lua.set_lua_paths/2`, the following functions cannot be sandboxed:
  > * `[:package]`
  > * `[:require]`
  >
  > By default these are sandboxed, see the `:exclude` option in `Lua.new/1` to allow them.
  """
  def set_lua_paths(%__MODULE__{} = lua, paths) when is_list(paths) do
    set_lua_paths(lua, Enum.join(paths, ";"))
  end

  def set_lua_paths(%__MODULE__{} = lua, paths) when is_binary(paths) do
    set!(lua, ["package", "path"], paths)
  end

  @doc """
  Sets a table value in Lua. Nested keys will allocate
  intermediate tables

      iex> Lua.set!(Lua.new(), [:hello], "World")

  It can also set nested values

      iex> Lua.set!(Lua.new(), [:a, :b, :c], [])

  These table values are availble in Lua scripts

      iex> lua = Lua.set!(Lua.new(), [:a, :b, :c], "nested!")
      iex> {result, _} = Lua.eval!(lua, "return a.b.c")
      iex> result
      ["nested!"]

  `Lua.set!/3` can also be used to expose Elixir functions

      iex> lua = Lua.set!(Lua.new(), [:sum], fn args -> [Enum.sum(args)] end)
      iex> {[10], _lua} = Lua.eval!(lua, "return sum(1, 2, 3, 4)")


  Functions can also take a second argument for the state of Lua

      iex> lua =
      ...>   Lua.set!(Lua.new(), [:set_count], fn args, state ->
      ...>     {[], Lua.set!(state, :count, Enum.count(args))}
      ...>   end)
      iex> {[3], _} = Lua.eval!(lua, "set_count(1, 2, 3); return count")

  """
  def set!(%__MODULE__{}, [], _) do
    raise Lua.RuntimeException, "Lua.set!/3 cannot have empty keys"
  end

  def set!(%__MODULE__{} = lua, keys, func) when is_function(func, 1) or is_function(func, 2) do
    {function_name, scope} = List.pop_at(keys, -1)

    func =
      case func do
        func when is_function(func, 1) ->
          fn data ->
            return = List.wrap(func.(data))

            if not Lua.Util.list_encoded?(return) do
              raise Lua.RuntimeException,
                function: function_name,
                scope: scope,
                message: "deflua functions must return encoded data, got #{inspect(return)}"
            end

            return
          end

        func when is_function(func, 2) ->
          fn args, state ->
            case func.(args, wrap(state)) do
              {:error, reason, %__MODULE__{} = lua} ->
                :luerl_lib.lua_error(reason, lua.state)

              {value, %__MODULE__{} = lua} ->
                value = List.wrap(value)

                if not Lua.Util.list_encoded?(value) do
                  raise Lua.RuntimeException,
                    function: function_name,
                    scope: scope,
                    message: "deflua functions must return encoded data, got #{inspect(value)}"
                end

                {value, lua.state}

              value ->
                value = List.wrap(value)

                if not Lua.Util.list_encoded?(value) do
                  raise Lua.RuntimeException,
                    function: function_name,
                    scope: scope,
                    message: "deflua functions must return encoded data, got #{inspect(value)}"
                end

                {value, state}
            end
          end
      end

    do_set(lua.state, keys, func)
  end

  def set!(%__MODULE__{} = lua, keys, value) do
    do_set(lua.state, keys, value)
  end

  defp do_set(state, keys, value) do
    {keys, state} = keys |> List.wrap() |> :luerl.encode_list(state)

    {_keys, state} =
      Enum.reduce_while(keys, {[], state}, fn key, {keys, state} ->
        keys = keys ++ [key]

        case :luerl.get_table_keys(keys, state) do
          {:ok, nil, state} ->
            {:cont, set_keys!(state, keys)}

          {:ok, _val, state} ->
            {:halt, {keys, state}}

          {:lua_error, _err, state} ->
            raise Lua.RuntimeException, {:lua_error, illegal_index(keys), state}
        end
      end)

    set_keys =
      if Lua.Util.encoded?(value) do
        &:luerl.set_table_keys/3
      else
        &:luerl.set_table_keys_dec/3
      end

    case set_keys.(keys, value, state) do
      {:ok, state} ->
        wrap(state)

      {:lua_error, _error, state} ->
        raise Lua.RuntimeException, {:lua_error, illegal_index(keys), state}
    end
  end

  defp set_keys!(state, keys) do
    {table, state} = :luerl_emul.alloc_table([], state)

    case :luerl.set_table_keys(keys, table, state) do
      {:ok, state} ->
        {keys, state}

      {:lua_error, _error, state} ->
        raise Lua.RuntimeException, {:lua_error, illegal_index(keys), state}
    end
  end

  defp illegal_index([:_G | keys]), do: illegal_index(keys)
  defp illegal_index(["_G" | keys]), do: illegal_index(keys)

  defp illegal_index(keys) do
    {:illegal_index, nil, Enum.join(keys, ".")}
  end

  @doc """
  Gets a table value in Lua

      iex> state = Lua.set!(Lua.new(), [:hello], "world")
      iex> Lua.get!(state, [:hello])
      "world"

  When a value doesn't exist, it returns nil

      iex> Lua.get!(Lua.new(), [:nope])
      nil

  It can also get nested values

      iex> state = Lua.set!(Lua.new(), [:a, :b, :c], "nested")
      iex> Lua.get!(state, [:a, :b, :c])
      "nested"

  ### Options
  * `:decode` - (default `true`) - By default, values are decoded
  """
  def get!(%__MODULE__{state: state}, keys, opts \\ []) when is_list(keys) do
    opts = Keyword.validate!(opts, decode: true)

    {keys, state} = :luerl.encode_list(keys, state)

    func =
      if opts[:decode] do
        &:luerl.get_table_keys_dec/2
      else
        &:luerl.get_table_keys/2
      end

    case func.(keys, state) do
      {:ok, value, _state} ->
        value

      {:lua_error, _, state} ->
        error = {:illegal_index, nil, Enum.join(keys, ".")}
        raise Lua.RuntimeException, {:lua_error, error, state}
    end
  end

  @doc """
  Evaluates the Lua script, returning any returned values and the updated
  Lua environment

      iex> {[42], _} = Lua.eval!(Lua.new(), "return 42")


  `eval!/2` can also evaluate chunks by passing instead of a script. As a
  performance optimization, it is recommended to call `load_chunk!/2` if you
  will be executing a chunk many times, but it is not necessary.

      iex> {[4], _} = Lua.eval!(~LUA[return 2 + 2]c)


  ### Options
  * `:decode` - (default `true`) By default, all values returned from Lua scripts are decoded.
                This may not be desirable if you need to modify a table reference or access a function call.
                Pass `decode: false` as an option to return encoded values
  """
  def eval!(script) do
    eval!(new(), script, [])
  end

  def eval!(script, opts) when is_binary(script) or is_struct(script, Lua.Chunk) do
    eval!(new(), script, opts)
  end

  def eval!(%__MODULE__{} = lua, script) do
    eval!(lua, script, [])
  end

  def eval!(%__MODULE__{state: state} = lua, script, opts) when is_binary(script) do
    opts = Keyword.validate!(opts, decode: true)

    func =
      if opts[:decode] do
        &:luerl.do_dec/2
      else
        &:luerl.do/2
      end

    case func.(script, state) do
      {:ok, result, new_state} ->
        {result, %__MODULE__{lua | state: new_state}}

      {:lua_error, _e, _state} = error ->
        raise Lua.RuntimeException, error

      {:error, [error | _], _} ->
        raise Lua.CompilerException, error
    end
  rescue
    e in [UndefinedFunctionError] ->
      reraise Lua.RuntimeException,
              Util.format_function([e.module, e.function], e.arity),
              __STACKTRACE__

    e in [Lua.RuntimeException, Lua.CompilerException] ->
      reraise e, __STACKTRACE__

    e ->
      reraise Lua.RuntimeException, e, __STACKTRACE__
  end

  def eval!(%__MODULE__{} = lua, %Lua.Chunk{} = chunk, opts) do
    opts = Keyword.validate!(opts, decode: true)

    {chunk, lua} = load_chunk!(lua, chunk)

    case :luerl.call_chunk(chunk.ref, lua.state) do
      {:ok, result, new_state} ->
        lua = %__MODULE__{lua | state: new_state}

        if opts[:decode] do
          {:luerl.decode_list(result, new_state), lua}
        else
          {result, lua}
        end

      {:lua_error, _e, _state} = error ->
        raise Lua.RuntimeException, error
    end
  rescue
    e in [UndefinedFunctionError] ->
      reraise Lua.RuntimeException,
              Util.format_function([e.module, e.function], e.arity),
              __STACKTRACE__

    e in [Lua.RuntimeException, Lua.CompilerException] ->
      reraise e, __STACKTRACE__

    e ->
      reraise Lua.RuntimeException, e, __STACKTRACE__
  end

  @doc """
  Parses a chunk of Lua code into a `t:Lua.Chunk.t/0`, which then can
  be loaded via `load_chunk!/2` or run via `eval!`.

  This function is particularly useful for checking Lua code for syntax
  erorrs and warnings at runtime. If you would like to just load a chunk,
  use `load_chunk!/1` instead.

      iex> {:ok, %Lua.Chunk{}} = Lua.parse_chunk("local foo = 1")

  Errors found during parsing will be returned as a list of formatted strings

      iex> Lua.parse_chunk("local foo =;")
      {:error, ["Line 1: syntax error before: ';'"]}

  """
  def parse_chunk(code) do
    case :luerl_comp.string(code, [:return]) do
      {:ok, chunk} ->
        {:ok, %Lua.Chunk{instructions: chunk}}

      {:error, errors, _warnings} ->
        {:error, Enum.map(errors, &Util.format_error/1)}
    end
  end

  @doc """
  Loads string or `t:Lua.Chunk.t/0` into state so that it can be
  evaluated via `eval!/2`

  Strings can be loaded as chunks, which are parsed and loaded

      iex> {%Lua.Chunk{}, %Lua{}} = Lua.load_chunk!(Lua.new(), "return 2 + 2")

  Or a pre-compiled chunk can be loaded as well. Loaded chunks will be marked as loaded,
  otherwise they will be re-loaded everytime `eval!/2` is called

      iex> {%Lua.Chunk{}, %Lua{}} = Lua.load_chunk!(Lua.new(), ~LUA[return 2 + 2]c)
  """
  def load_chunk!(%__MODULE__{} = lua, code) when is_binary(code) do
    case parse_chunk(code) do
      {:ok, chunk} -> load_chunk!(lua, chunk)
      {:error, errors} -> raise Lua.CompilerException, formatted: errors
    end
  end

  def load_chunk!(%__MODULE__{state: state} = lua, %Lua.Chunk{ref: nil} = chunk) do
    {ref, state} = :luerl_emul.load_chunk(chunk.instructions, state)

    {%Lua.Chunk{chunk | ref: ref}, %__MODULE__{lua | state: state}}
  end

  def load_chunk!(%__MODULE__{} = lua, %Lua.Chunk{} = chunk) do
    {chunk, lua}
  end

  @doc """
  Calls a function in Lua's state

      iex> {:ok, [ret], _lua} = Lua.call_function(Lua.new(), [:string, :lower], ["HELLO ROBERT"])
      iex> ret
      "hello robert"

  References to functions can also be passed

      iex> {[ref], lua} = Lua.eval!("return string.lower", decode: false)
      iex> {:ok, [ret], _lua} = Lua.call_function(lua, ref, ["FUNCTION REF"])
      iex> ret
      "function ref"

  """
  def call_function(%__MODULE__{} = lua, ref, args) when is_tuple(ref) do
    case :luerl.call(ref, args, lua.state) do
      {:ok, value, state} -> {:ok, value, wrap(state)}
      {:lua_error, reason, state} -> {:error, reason, wrap(state)}
    end
  end

  def call_function(%__MODULE__{} = lua, name, args) when is_function(name) do
    {ref, lua} = encode!(lua, name)

    case :luerl.call(ref, args, lua.state) do
      {:ok, value, state} -> {:ok, value, wrap(state)}
      {:lua_error, reason, state} -> {:error, reason, wrap(state)}
    end
  end

  def call_function(%__MODULE__{} = lua, name, args) do
    {keys, state} = List.wrap(name) |> :luerl.encode_list(lua.state)

    func = get!(lua, keys, decode: false)

    case :luerl.call_function(func, args, state) do
      {:ok, ret, lua} -> {:ok, ret, wrap(lua)}
      {:lua_error, reason, state} -> {:error, reason, wrap(state)}
    end
  end

  @doc """
  The raising variant of `call_function/3`

  This is also useful for executing Lua function's inside of Elixir APIs

  ```elixir
  defmodule MyAPI do
    use Lua.API, scope: "example"

    deflua foo(value), state do
      Lua.call_function!(state, [:string, :lower], [value])
    end
  end

  lua = Lua.new() |> Lua.load_api(MyAPI)

  {["wow"], _} = Lua.eval!(lua, "return example.foo(\"WOW\")")
  ```
  """
  def call_function!(%__MODULE__{} = lua, func, args) do
    case call_function(lua, func, args) do
      {:ok, ret, lua} -> {ret, lua}
      {:error, reason, lua} -> raise Lua.RuntimeException, {:lua_error, reason, lua.state}
    end
  end

  @doc """
  Encodes a Lua value into its internal form

      iex> {encoded, _} = Lua.encode!(Lua.new(), %{a: 1})
      iex> encoded
      {:tref, 14}
  """
  def encode!(%__MODULE__{} = lua, value) do
    {encoded, state} = :luerl.encode(value, lua.state)
    {encoded, wrap(state)}
  rescue
    ArgumentError ->
      reraise Lua.RuntimeException, "Failed to encode #{inspect(value)}", __STACKTRACE__
  end

  @doc """
  Encodes a list of values into a list of encoded value

  Useful for encoding lists of return values

      iex> {[1, {:tref, _}, true], _} = Lua.encode_list!(Lua.new(), [1, %{a: 2}, true])
  """
  def encode_list!(%__MODULE__{} = lua, list) when is_list(list) do
    Enum.map_reduce(list, lua, &encode!(&2, &1))
  end

  @doc """
  Decodes a Lua value from its internal form

      iex> {encoded, lua} = Lua.encode!(Lua.new(), %{a: 1})
      iex> Lua.decode!(lua, encoded)
      [{"a", 1}]

  """
  def decode!(%__MODULE__{} = lua, value) do
    :luerl.decode(value, lua.state)
  rescue
    ArgumentError ->
      reraise Lua.RuntimeException, "Failed to decode #{inspect(value)}", __STACKTRACE__
  end

  @doc """
  Decodes a list of encoded values

  Useful for decoding all function arguments in a `deflua`

      iex> {encoded, lua} = Lua.encode_list!(Lua.new(), [1, %{a: 2}, true])
      iex> Lua.decode_list!(lua, encoded)
      [1, [{"a", 2}], true]
  """
  def decode_list!(%__MODULE__{} = lua, list) when is_list(list) do
    Enum.map(list, &decode!(lua, &1))
  end

  @doc """
  Loads a Lua file into the environment. Any values returned in the global
  scope are thrown away.

  Mimics the functionality of Lua's [dofile](https://www.lua.org/manual/5.4/manual.html#pdf-dofile)
  """
  def load_file!(%__MODULE__{state: state} = lua, path) when is_binary(path) do
    case :luerl.dofile(String.to_charlist(path), [:return], state) do
      {:ok, _, state} ->
        %__MODULE__{lua | state: state}

      {:lua_error, _error, _lua} = error ->
        raise Lua.CompilerException, error

      {:error, [{:none, :file, :enoent} | _], _} ->
        raise "Cannot load lua file, #{inspect(path <> ".lua")} does not exist"

      {:error, [error | _], _} ->
        # We just take the first error
        raise Lua.CompilerException, error
    end
  end

  @doc """
  Inject functions written with the `deflua` macro into the Lua runtime.

  See `Lua.API` for more information on writing api modules

  ### Options
  * `:scope` - (optional) scope, overriding whatever is provided in `use Lua.API, scope: ...`
  * `:data` - (optional) - data to be passed to the Lua.API.install/3 callback

  """
  def load_api(lua, module, opts \\ []) do
    opts = Keyword.validate!(opts, [:scope, :data])
    funcs = :functions |> module.__info__() |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    scope = opts[:scope] || module.scope()

    lua = ensure_scope!(lua, scope)

    module.__lua_functions__()
    |> Enum.reduce(lua, fn {name, with_state?, variadic?}, lua ->
      arities = Map.get(funcs, name)

      do_set(
        lua.state,
        List.wrap(scope) ++ [name],
        if variadic? do
          wrap_variadic_function(module, name, with_state?)
        else
          wrap_function(module, name, arities, with_state?)
        end
      )
    end)
    |> Lua.API.install(module, scope, opts[:data])
  end

  @doc """
  Puts a private value in storage for use in Elixir functions

      iex> Lua.new() |> Lua.put_private(:api_key, "1234")
  """
  def put_private(%__MODULE__{} = lua, key, value) do
    update_in(lua.state, fn state -> :luerl.put_private(key, value, state) end)
  end

  @doc """
  Gets a private value in storage for use in Elixir functions

      iex> lua = Lua.new() |> Lua.put_private(:api_key, "1234")
      iex> Lua.get_private(lua, :api_key)
      {:ok, "1234"}
  """
  def get_private(%__MODULE__{state: state}, key) do
    {:ok, :luerl.get_private(key, state)}
  rescue
    KeyError -> :error
  end

  @doc """
  Gets a private value in storage for use in Elixir functions, raises if the key doesn't exist

      iex> lua = Lua.new() |> Lua.put_private(:api_key, "1234")
      iex> Lua.get_private!(lua, :api_key)
      "1234"
  """
  def get_private!(%__MODULE__{} = lua, key) do
    case get_private(lua, key) do
      {:ok, value} -> value
      :error -> raise "private key `#{inspect(key)}` does not exist"
    end
  end

  @doc """
  Deletes a key from private storage

      iex> lua = Lua.new() |> Lua.put_private(:api_key, "1234")
      iex> lua = Lua.delete_private(lua, :api_key)
      iex> Lua.get_private(lua, :api_key)
      :error
  """
  def delete_private(%__MODULE__{} = lua, key) do
    update_in(lua.state, fn state -> :luerl.delete_private(key, state) end)
  end

  defp wrap_variadic_function(module, function_name, with_state?) do
    # formatted = Util.format_function(module.scope() ++ [function_name], 0)

    if with_state? do
      fn args, state ->
        execute_function(module, function_name, [args, wrap(state)], wrap(state))
      end
    else
      fn args, state ->
        execute_function(module, function_name, [args], wrap(state))
      end
    end
  end

  # credo:disable-for-lines:25
  defp wrap_function(module, function_name, arities, with_state?) do
    # formatted = Util.format_function(module.scope() ++ [function_name], 0)

    if with_state? do
      fn args, state ->
        if (length(args) + 1) in arities do
          execute_function(module, function_name, args ++ [wrap(state)], wrap(state))
        else
          arities = Enum.map(arities, &(&1 - 1))

          raise Lua.RuntimeException,
            function: function_name,
            scope: module.scope(),
            message: "expected #{Enum.join(arities, " or ")} arguments, got #{length(args)}"
        end
      end
    else
      fn args, state ->
        if length(args) in arities do
          execute_function(module, function_name, args, wrap(state))
        else
          raise Lua.RuntimeException,
            function: function_name,
            scope: module.scope(),
            message: "expected #{Enum.join(arities, " or ")} arguments, got #{length(args)}"
        end
      end
    end
  end

  defp execute_function(module, function_name, args, lua) do
    # Luerl mandates lists as return values; this function ensures all results conform.
    case apply(module, function_name, args) do
      # Table-like keyword list
      [{_, _} | _rest] ->
        raise Lua.RuntimeException,
          function: function_name,
          scope: module.scope(),
          message: "keyword lists must be explicitly encoded to tables using Lua.encode!/2"

      # Map
      map when is_map(map) ->
        raise Lua.RuntimeException,
          function: function_name,
          scope: module.scope(),
          message: "maps must be explicitly encoded to tables using Lua.encode!/2"

      {:error, reason} ->
        :luerl_lib.lua_error(reason, lua.state)

      {:error, reason, %Lua{} = lua} ->
        :luerl_lib.lua_error(reason, lua.state)

      {data, %Lua{} = lua} ->
        data = List.wrap(data)

        if not Lua.Util.list_encoded?(data) do
          raise Lua.RuntimeException,
            function: function_name,
            scope: module.scope(),
            message: "deflua functions must return encoded data, got #{inspect(data)}"
        end

        {data, lua.state}

      data ->
        data = List.wrap(data)

        if not Lua.Util.list_encoded?(data) do
          raise Lua.RuntimeException,
            function: function_name,
            scope: module.scope(),
            message: "deflua functions must return encoded data, got #{inspect(data)}"
        end

        {data, lua.state}
    end
  catch
    thrown_value ->
      {:error,
       "Value thrown during function '#{function_name}' execution: #{inspect(thrown_value)}"}
  end

  defp ensure_scope!(lua, []) do
    lua
  end

  defp ensure_scope!(lua, scope) do
    set!(lua, scope, %{})
  end

  defp wrap(state), do: %__MODULE__{state: state}
end
