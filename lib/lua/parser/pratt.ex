defmodule Lua.Parser.Pratt do
  @moduledoc """
  Pratt parser for Lua expressions.

  Implements operator precedence parsing using binding powers.
  Handles all Lua 5.3 precedence levels including bitwise operators.

  Precedence (lowest to highest):
  1. or
  2. and
  3. < > <= >= ~= ==
  4. |
  5. ~
  6. &
  7. << >>
  8. ..
  9. + -
  10. * / // %
  11. unary (not # - ~)
  12. ^
  """

  alias Lua.AST.Expr

  @doc """
  Returns the binding power (precedence) for binary operators.

  Returns {left_bp, right_bp} where:
  - left_bp: minimum precedence of left operand
  - right_bp: minimum precedence of right operand

  Right associative operators have left_bp < right_bp.
  Left associative operators have left_bp >= right_bp.
  """
  @spec binding_power(atom()) :: {non_neg_integer(), non_neg_integer()} | nil
  def binding_power(:or), do: {1, 2}
  def binding_power(:and), do: {3, 4}

  # Comparison operators (left associative)
  def binding_power(:lt), do: {5, 6}
  def binding_power(:gt), do: {5, 6}
  def binding_power(:le), do: {5, 6}
  def binding_power(:ge), do: {5, 6}
  def binding_power(:ne), do: {5, 6}
  def binding_power(:eq), do: {5, 6}

  # Bitwise OR (left associative)
  def binding_power(:bor), do: {7, 8}

  # Bitwise XOR (left associative)
  def binding_power(:bxor), do: {9, 10}

  # Bitwise AND (left associative)
  def binding_power(:band), do: {11, 12}

  # Bitwise shifts (left associative)
  def binding_power(:shl), do: {13, 14}
  def binding_power(:shr), do: {13, 14}

  # String concatenation (right associative)
  def binding_power(:concat), do: {15, 14}

  # Additive (left associative)
  def binding_power(:add), do: {17, 18}
  def binding_power(:sub), do: {17, 18}

  # Multiplicative (left associative)
  def binding_power(:mul), do: {19, 20}
  def binding_power(:div), do: {19, 20}
  def binding_power(:floordiv), do: {19, 20}
  def binding_power(:mod), do: {19, 20}

  # Unary operators
  def binding_power(:not), do: {21, 22}
  def binding_power(:neg), do: {21, 22}
  def binding_power(:len), do: {21, 22}

  # Power (right associative)
  def binding_power(:pow), do: {24, 23}

  # Not a binary operator
  def binding_power(_), do: nil

  @doc """
  Returns the binding power for unary prefix operators.

  This is the minimum precedence required for the operand.

  Note: In Lua, unary minus has an unusual precedence - it's lower than power (^).
  So -2^3 = -(2^3), not (-2)^3.
  To achieve this: unary minus binding power (13) < power left_bp (16),
  allowing power to bind within the unary's operand.
  But 13 > multiplication left_bp (11), so -a*b = (-a)*b.
  """
  @spec prefix_binding_power(atom()) :: non_neg_integer() | nil
  def prefix_binding_power(:not), do: 22
  # Between mult (19) and power (24)
  def prefix_binding_power(:sub), do: 21
  def prefix_binding_power(:len), do: 22
  # ~ as unary bitwise not
  def prefix_binding_power(:bxor), do: 22
  def prefix_binding_power(_), do: nil

  @doc """
  Maps token operators to AST binary operators.
  """
  @spec token_to_binop(atom()) :: Expr.BinOp.op() | nil
  def token_to_binop(:or), do: :or
  def token_to_binop(:and), do: :and
  def token_to_binop(:lt), do: :lt
  def token_to_binop(:gt), do: :gt
  def token_to_binop(:le), do: :le
  def token_to_binop(:ge), do: :ge
  def token_to_binop(:ne), do: :ne
  def token_to_binop(:eq), do: :eq
  def token_to_binop(:concat), do: :concat
  def token_to_binop(:add), do: :add
  def token_to_binop(:sub), do: :sub
  def token_to_binop(:mul), do: :mul
  def token_to_binop(:div), do: :div
  def token_to_binop(:floordiv), do: :floordiv
  def token_to_binop(:mod), do: :mod
  def token_to_binop(:pow), do: :pow
  def token_to_binop(:band), do: :band
  def token_to_binop(:bor), do: :bor
  def token_to_binop(:bxor), do: :bxor
  def token_to_binop(:shl), do: :shl
  def token_to_binop(:shr), do: :shr
  def token_to_binop(_), do: nil

  @doc """
  Maps token operators to AST unary operators.
  """
  @spec token_to_unop(atom()) :: Expr.UnOp.op() | nil
  def token_to_unop(:not), do: :not
  def token_to_unop(:sub), do: :neg
  def token_to_unop(:len), do: :len
  # ~ as unary bitwise not
  def token_to_unop(:bxor), do: :bnot
  def token_to_unop(_), do: nil

  @doc """
  Checks if a token is a binary operator.
  """
  @spec is_binary_op?(atom()) :: boolean()
  def is_binary_op?(op) do
    binding_power(op) != nil
  end

  @doc """
  Checks if a token is a prefix unary operator.
  """
  @spec is_prefix_op?(atom()) :: boolean()
  def is_prefix_op?(op) do
    prefix_binding_power(op) != nil
  end
end
