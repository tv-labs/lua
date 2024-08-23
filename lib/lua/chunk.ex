defmodule Lua.Chunk do
  @moduledoc """
  A pre-compiled [chunk](https://www.lua.org/pil/1.1.html) of Lua code
  that can be executed at a future point in time
  """

  @type t :: %__MODULE__{}

  defstruct [:instructions, :ref]
end
