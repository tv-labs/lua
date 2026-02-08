defmodule Lua.VM.Table do
  @moduledoc """
  Lua table data structure.

  A single Elixir map backing both array and hash portions.
  Keys and values are VM values (numbers, strings, booleans, `{:tref, id}`, etc.).
  Integer keys use 1-based indexing per Lua convention.
  """

  defstruct data: %{},
            metatable: nil

  @type t :: %__MODULE__{
          data: %{optional(term()) => term()},
          metatable: {:tref, non_neg_integer()} | nil
        }
end
