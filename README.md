# Lua

<!-- MDOC !-->

Lua is an ergonomic interface to [Luerl](https://github.com/rvirding/luerl), aiming to be the best way to use Luerl from Elixir.

## Features

* Ergonomic API for Elixir <> Lua FFI
* Improved error messages
* Deep-setting variables and state
* Excellent documentation and guides for working with Luerl

## Usage

### Executing Lua

Lua can be run using the `eval!/2` function

``` elixir
    iex> {[4], _} =
    ...>   Lua.eval!("""
    ...>   return 2 + 2
    ...>   """)

```

### Exposing Elixir functions to Lua

`Lua` provides the `deflua` macro for exposing Elixir functions to Lua

    defmodule MyAPI do
      use Lua.API
      
      deflua double(v), do: 2 * v
    end
    
    lua = Lua.new() |> Lua.inject_module(MyAPI) 

    {[10], _} = 
      Lua.eval!(lua, """
      return double(5)
      """)
