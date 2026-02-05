defmodule Lua.AST.Expr do
  @moduledoc """
  Expression AST nodes for Lua.

  All expression nodes include a `meta` field for position tracking.
  """

  alias Lua.AST.Meta

  @type t ::
          Nil.t()
          | Bool.t()
          | Number.t()
          | String.t()
          | Var.t()
          | BinOp.t()
          | UnOp.t()
          | Table.t()
          | Call.t()
          | MethodCall.t()
          | Index.t()
          | Property.t()
          | Function.t()
          | Vararg.t()

  defmodule Nil do
    @moduledoc "Represents the `nil` literal"
    defstruct [:meta]
    @type t :: %__MODULE__{meta: Meta.t() | nil}
  end

  defmodule Bool do
    @moduledoc "Represents boolean literals (`true` or `false`)"
    defstruct [:value, :meta]
    @type t :: %__MODULE__{value: boolean(), meta: Meta.t() | nil}
  end

  defmodule Number do
    @moduledoc "Represents numeric literals (integers and floats)"
    defstruct [:value, :meta]
    @type t :: %__MODULE__{value: number(), meta: Meta.t() | nil}
  end

  defmodule String do
    @moduledoc "Represents string literals"
    defstruct [:value, :meta]
    @type t :: %__MODULE__{value: String.t(), meta: Meta.t() | nil}
  end

  defmodule Var do
    @moduledoc "Represents a variable reference"
    defstruct [:name, :meta]
    @type t :: %__MODULE__{name: String.t(), meta: Meta.t() | nil}
  end

  defmodule BinOp do
    @moduledoc """
    Represents a binary operation.

    Operators:
    - Arithmetic: `:add`, `:sub`, `:mul`, `:div`, `:floordiv`, `:mod`, `:pow`
    - Comparison: `:eq`, `:ne`, `:lt`, `:le`, `:gt`, `:ge`
    - Logical: `:and`, `:or`
    - String: `:concat`
    """
    defstruct [:op, :left, :right, :meta]

    @type op ::
            :add
            | :sub
            | :mul
            | :div
            | :floordiv
            | :mod
            | :pow
            | :eq
            | :ne
            | :lt
            | :le
            | :gt
            | :ge
            | :and
            | :or
            | :concat

    @type t :: %__MODULE__{
            op: op(),
            left: Lua.AST.Expr.t(),
            right: Lua.AST.Expr.t(),
            meta: Meta.t() | nil
          }
  end

  defmodule UnOp do
    @moduledoc """
    Represents a unary operation.

    Operators:
    - `:not` - logical not
    - `:neg` - arithmetic negation (-)
    - `:len` - length operator (#)
    """
    defstruct [:op, :operand, :meta]

    @type op :: :not | :neg | :len

    @type t :: %__MODULE__{
            op: op(),
            operand: Lua.AST.Expr.t(),
            meta: Meta.t() | nil
          }
  end

  defmodule Table do
    @moduledoc """
    Represents a table constructor: `{...}`

    Fields can be:
    - List entries: `{1, 2, 3}`  -> `[{:list, expr}, ...]`
    - Key-value pairs: `{a = 1}` -> `[{:pair, key_expr, val_expr}, ...]`
    - Computed keys: `{["key"] = value}` -> `[{:pair, key_expr, val_expr}, ...]`
    """
    defstruct [:fields, :meta]

    @type field ::
            {:list, Lua.AST.Expr.t()}
            | {:pair, Lua.AST.Expr.t(), Lua.AST.Expr.t()}

    @type t :: %__MODULE__{
            fields: [field()],
            meta: Meta.t() | nil
          }
  end

  defmodule Call do
    @moduledoc """
    Represents a function call: `func(args)`
    """
    defstruct [:func, :args, :meta]

    @type t :: %__MODULE__{
            func: Lua.AST.Expr.t(),
            args: [Lua.AST.Expr.t()],
            meta: Meta.t() | nil
          }
  end

  defmodule MethodCall do
    @moduledoc """
    Represents a method call: `obj:method(args)`

    This is syntactic sugar for `obj.method(obj, args)` in Lua.
    """
    defstruct [:object, :method, :args, :meta]

    @type t :: %__MODULE__{
            object: Lua.AST.Expr.t(),
            method: String.t(),
            args: [Lua.AST.Expr.t()],
            meta: Meta.t() | nil
          }
  end

  defmodule Index do
    @moduledoc """
    Represents indexing with brackets: `table[key]`
    """
    defstruct [:table, :key, :meta]

    @type t :: %__MODULE__{
            table: Lua.AST.Expr.t(),
            key: Lua.AST.Expr.t(),
            meta: Meta.t() | nil
          }
  end

  defmodule Property do
    @moduledoc """
    Represents property access: `table.field`

    This is syntactic sugar for `table["field"]` in Lua.
    """
    defstruct [:table, :field, :meta]

    @type t :: %__MODULE__{
            table: Lua.AST.Expr.t(),
            field: String.t(),
            meta: Meta.t() | nil
          }
  end

  defmodule Function do
    @moduledoc """
    Represents a function expression: `function(params) body end`

    Params can include:
    - Named parameters: `["a", "b", "c"]`
    - Vararg: `{:vararg}` as the last element
    """
    defstruct [:params, :body, :meta]

    @type param :: String.t() | :vararg

    @type t :: %__MODULE__{
            params: [param()],
            body: Lua.AST.Block.t(),
            meta: Meta.t() | nil
          }
  end

  defmodule Vararg do
    @moduledoc "Represents the vararg expression: `...`"
    defstruct [:meta]
    @type t :: %__MODULE__{meta: Meta.t() | nil}
  end
end
