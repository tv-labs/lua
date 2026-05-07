# Lua

<!-- MDOC !-->

`Lua` is an Elixir-native Lua 5.3 virtual machine. It runs Lua code on the BEAM
with no Erlang or C dependencies, and exposes an ergonomic Elixir API for
embedding Lua scripting in your application.

## Features

* Pure-Elixir implementation of Lua 5.3 — lexer, parser, register-based VM,
  and standard library — running directly on the BEAM
* `~LUA` sigil for validating (and optionally pre-compiling) Lua code at
  compile time
* `deflua` macro for exposing Elixir functions to Lua
* Beautiful error messages and stack traces
* Sandboxing of stdlib paths
* Deep setting/getting of variables and state from Elixir
* Pattern-matching, metatables, varargs, multiple returns, `_G`/`_ENV`,
  `string`/`table`/`math`/`debug` libraries, and the `string.find`/`match`/
  `gmatch`/`gsub` pattern engine

> #### Lua the Elixir library vs Lua the language {: .info}
> When referring to this library, `Lua` will be stylized as a link.
>
> References to Lua the language will be in plaintext and not linked.

## Executing Lua

`Lua` can be run using the `eval!/2` function

    iex> {[4], _} = Lua.eval!("return 2 + 2")

## Compile-time validation

Use the `~LUA` sigil to parse and validate your Lua code at compile time

    iex> import Lua, only: [sigil_LUA: 2]

    #iex> {[4], _} = Lua.eval!(~LUA[return 2 +])
    ** (Lua.CompilerException) Failed to compile Lua!

Using the `c` modifier transforms your Lua code into a `t:Lua.Chunk.t/0` at compile-time,
which will speed up execution at runtime since the Lua no longer needs to be parsed

    iex> import Lua, only: [sigil_LUA: 2]
    iex> {[4], _} = Lua.eval!(~LUA[return 2 + 2]c)

## Exposing Elixir functions to Lua

The simplest way to expose an Elixir function to Lua is using the `Lua.set!/3` function

``` elixir
import Lua, only: [sigil_LUA: 2]

lua = 
  Lua.set!(Lua.new(), [:sum], fn args ->
    [Enum.sum(args)]
  end)

{[10], _} = Lua.eval!(lua, ~LUA[return sum(1, 2, 3, 4)]c)
```

For easily expressing APIs, `Lua` provides the `deflua` macro for exposing Elixir functions to Lua

``` elixir
defmodule MyAPI do
  use Lua.API
      
  deflua double(v), do: 2 * v
end

import Lua, only: [sigil_LUA: 2]
    
lua = Lua.new() |> Lua.load_api(MyAPI)

{[10], _} = Lua.eval!(lua, ~LUA[return double(5)])
```

## Calling Lua functions from Elixir

`Lua` can be used to expose complex functions written in Elixir. In some cases, you may want to call Lua functions from Elixir. This can
be achieved with the `Lua.call_function!/3` function

``` elixir
defmodule MyAPI do
  use Lua.API, scope: "example"

  deflua foo(value), state do
    Lua.call_function!(state, [:string, :lower], [value])
  end
end

import Lua, only: [sigil_LUA: 2]

lua = Lua.new() |> Lua.load_api(MyAPI)

{["wow"], _} = Lua.eval!(lua, ~LUA[return example.foo("WOW")])
```

## Modify Lua state from Elixir

You can also use `Lua` to modify the state of the lua environment inside your Elixir code. Imagine you have a queue module that you
want to implement in Elixir, with the queue stored in a global variable

``` elixir
defmodule Queue do
  use Lua.API, scope: "q"
  
  deflua push(v), state do
    # Pull out the global variable "my_queue" from lua
    queue = Lua.get!(state, [:my_queue])
    
    # Call the Lua function table.insert(table, value)
    {[], state} = Lua.call_function!(state, [:table, :insert], [queue, v])
    
    # Return the modified lua state with no return values
    {[], state}
  end
end

import Lua, only: [sigil_LUA: 2]

lua = Lua.new() |> Lua.load_api(Queue)

{[queue], _} =
  Lua.eval!(lua, """
  my_queue = {}

  q.push("first")
  q.push("second")

  return my_queue
  """)
  
["first", "second"] = Lua.Table.as_list(queue)
```

## Accessing private state from Elixir

When building applications with `Lua`, you may find yourself in need of propagating extra context for use in your APIs. For instance, you may want to access information about the current user who executed the Lua script, an API key, or something else that is private and should not be available to the Lua code. For this, we have the `Lua.put_private/3`, `Lua.get_private/2`, and `Lua.delete_private/2` functions.

For example, imagine you wanted to allow the user to access information about themselves

``` elixir
defmodule User do
  defstruct [:name]
end

defmodule UserAPI do
  use Lua.API, scope: "user"
  
  deflua name(), state do
    user = Lua.get_private!(state, :user) 
    
    {[user.name], state}
  end
end

user = %User{name: "Robert Virding"}

lua = Lua.new() |> Lua.put_private(:user, user) |> Lua.load_api(UserAPI)

{["Hello Robert Virding"], _lua} = Lua.eval!(lua, ~LUA"""
  return "Hello " .. user.name()
""")
```

This allows you to have simple, expressive APIs that access context that is unavailable to the Lua code.

## Encoding and Decoding data

When working with `Lua`, you may want to inject data of various types into the runtime. Some values, such as integers, have the same representation inside the VM as they do in Elixir and do not require encoding. Other values, such as maps, are represented inside the VM as tables and must be encoded first. Arbitrary Elixir terms can be passed across the boundary using a `{:userdata, any()}` tuple.

Values may be encoded with `Lua.encode!/2`.

  Elixir type                 | Internal VM type            | Requires encoding?
  :-------------------------- | :-------------------------- | :---------------------
  `nil`                       | `nil`                       | no
  `boolean()`                 | `boolean()`                 | no
  `number()`                  | `number()`                  | no
  `binary()`                  | `binary()`                  | no
  `atom()`                    | `binary()`                  | yes
  `map()`                     | `{:tref, integer()}`        | yes
  `{:userdata, any()}`        | `{:udref, integer()}`       | yes
  `(any()) -> any()`          | `{:native_func, fun}`       | yes
  `(any(), Lua.t()) -> any()` | `{:native_func, fun}`       | yes
  `list(any())`               | `list(VM type)`             | maybe (if any of its values require encoding)
  

## Userdata

There are situations where you want to pass around a reference to some Elixir datastructure, such as a struct. In these situations, you can use a `{:userdata, any()}` tuple.

``` elixir
defmodule Thing do
  defstruct [:value]
end

{encoded, lua} = Lua.encode!(Lua.new(), {:userdata, %Thing{value: "1234"}})

lua = Lua.set!(lua, [:foo], encoded)

{[{:userdata, %Thing{value: "1234"}}], _} = Lua.eval!(lua, "return foo")
```

Trying to deference userdata inside a Lua program will result in an exception.
  
  
## Credits

`Lua` started as an ergonomic Elixir wrapper around Robert Virding's
[Luerl](https://github.com/rvirding/luerl) project. As of `1.0.0` this library
is a full Elixir-native reimplementation of the Lua 5.3 lexer, parser, and
virtual machine, with a public API designed to feel idiomatic from Elixir.
Luerl deserves credit as the prior art that made this possible — its design
informed many of the decisions in the new VM, and we benchmark against it.
