defmodule Lua.AST.Statement do
  @moduledoc """
  Statement AST nodes for Lua.

  All statement nodes include a `meta` field for position tracking.
  """

  alias Lua.AST.{Meta, Expr, Block}

  defmodule Assign do
    @moduledoc """
    Represents an assignment statement: `targets = values`

    Both targets and values can be lists for multiple assignment:
    `a, b = 1, 2`
    """
    defstruct [:targets, :values, :meta]

    @type t :: %__MODULE__{
            targets: [Expr.t()],
            values: [Expr.t()],
            meta: Meta.t() | nil
          }
  end

  defmodule Local do
    @moduledoc """
    Represents a local variable declaration: `local names = values`

    Values can be empty for declaration without initialization.
    """
    defstruct [:names, :values, :meta]

    @type t :: %__MODULE__{
            names: [String.t()],
            values: [Expr.t()],
            meta: Meta.t() | nil
          }
  end

  defmodule LocalFunc do
    @moduledoc """
    Represents a local function declaration: `local function name(params) body end`
    """
    defstruct [:name, :params, :body, :meta]

    @type t :: %__MODULE__{
            name: String.t(),
            params: [Expr.Function.param()],
            body: Block.t(),
            meta: Meta.t() | nil
          }
  end

  defmodule FuncDecl do
    @moduledoc """
    Represents a function declaration: `function name(params) body end`

    The name can be a path for nested names:
    - `function foo() end` -> name: `["foo"]`, is_method: false
    - `function a.b.c() end` -> name: `["a", "b", "c"]`, is_method: false
    - `function obj:method() end` -> name: `["obj", "method"]`, is_method: true

    When `is_method` is true, an implicit `self` parameter is added.
    """
    defstruct [:name, :params, :body, :is_method, :meta]

    @type t :: %__MODULE__{
            name: [String.t()],
            params: [Expr.Function.param()],
            body: Block.t(),
            is_method: boolean(),
            meta: Meta.t() | nil
          }
  end

  defmodule CallStmt do
    @moduledoc """
    Represents a function call as a statement.

    In Lua, function calls can be expressions or statements.
    """
    defstruct [:call, :meta]

    @type t :: %__MODULE__{
            call: Expr.Call.t() | Expr.MethodCall.t(),
            meta: Meta.t() | nil
          }
  end

  defmodule If do
    @moduledoc """
    Represents an if statement with optional elseif and else clauses.

    ```lua
    if condition then
      block
    elseif condition2 then
      block2
    else
      else_block
    end
    ```
    """
    defstruct [:condition, :then_block, :elseifs, :else_block, :meta]

    @type elseif_clause :: {Expr.t(), Block.t()}

    @type t :: %__MODULE__{
            condition: Expr.t(),
            then_block: Block.t(),
            elseifs: [elseif_clause()],
            else_block: Block.t() | nil,
            meta: Meta.t() | nil
          }
  end

  defmodule While do
    @moduledoc """
    Represents a while loop: `while condition do block end`
    """
    defstruct [:condition, :body, :meta]

    @type t :: %__MODULE__{
            condition: Expr.t(),
            body: Block.t(),
            meta: Meta.t() | nil
          }
  end

  defmodule Repeat do
    @moduledoc """
    Represents a repeat-until loop: `repeat block until condition`
    """
    defstruct [:body, :condition, :meta]

    @type t :: %__MODULE__{
            body: Block.t(),
            condition: Expr.t(),
            meta: Meta.t() | nil
          }
  end

  defmodule ForNum do
    @moduledoc """
    Represents a numeric for loop: `for var = start, limit, step do block end`

    The step is optional and defaults to 1.
    """
    defstruct [:var, :start, :limit, :step, :body, :meta]

    @type t :: %__MODULE__{
            var: String.t(),
            start: Expr.t(),
            limit: Expr.t(),
            step: Expr.t() | nil,
            body: Block.t(),
            meta: Meta.t() | nil
          }
  end

  defmodule ForIn do
    @moduledoc """
    Represents a generic for loop: `for vars in exprs do block end`

    ```lua
    for k, v in pairs(t) do
      -- block
    end
    ```
    """
    defstruct [:vars, :iterators, :body, :meta]

    @type t :: %__MODULE__{
            vars: [String.t()],
            iterators: [Expr.t()],
            body: Block.t(),
            meta: Meta.t() | nil
          }
  end

  defmodule Do do
    @moduledoc """
    Represents a do block: `do block end`

    Used to create a new scope.
    """
    defstruct [:body, :meta]

    @type t :: %__MODULE__{
            body: Block.t(),
            meta: Meta.t() | nil
          }
  end

  defmodule Return do
    @moduledoc """
    Represents a return statement: `return exprs`

    Can return multiple values.
    """
    defstruct [:values, :meta]

    @type t :: %__MODULE__{
            values: [Expr.t()],
            meta: Meta.t() | nil
          }
  end

  defmodule Break do
    @moduledoc """
    Represents a break statement: `break`
    """
    defstruct [:meta]
    @type t :: %__MODULE__{meta: Meta.t() | nil}
  end

  defmodule Goto do
    @moduledoc """
    Represents a goto statement: `goto label`

    Introduced in Lua 5.2.
    """
    defstruct [:label, :meta]

    @type t :: %__MODULE__{
            label: String.t(),
            meta: Meta.t() | nil
          }
  end

  defmodule Label do
    @moduledoc """
    Represents a label: `::label::`

    Introduced in Lua 5.2.
    """
    defstruct [:name, :meta]

    @type t :: %__MODULE__{
            name: String.t(),
            meta: Meta.t() | nil
          }
  end

  @type t ::
          Assign.t()
          | Local.t()
          | LocalFunc.t()
          | FuncDecl.t()
          | CallStmt.t()
          | If.t()
          | While.t()
          | Repeat.t()
          | ForNum.t()
          | ForIn.t()
          | Do.t()
          | Return.t()
          | Break.t()
          | Goto.t()
          | Label.t()
end
