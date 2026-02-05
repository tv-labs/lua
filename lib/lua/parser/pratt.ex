defmodule Lua.Parser.Pratt do
  @moduledoc """
  Pratt parser for Lua expressions.

  Implements operator precedence parsing using binding powers.
  Handles all 11 precedence levels in Lua 5.3.

  Precedence (lowest to highest):
  1. or
  2. and
  3. < > <= >= ~= ==
  4. ..
  5. + -
  6. * / // %
  7. unary (not # -)
  8. ^
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

  # String concatenation (right associative)
  def binding_power(:concat), do: {7, 6}

  # Additive (left associative)
  def binding_power(:add), do: {9, 10}
  def binding_power(:sub), do: {9, 10}

  # Multiplicative (left associative)
  def binding_power(:mul), do: {11, 12}
  def binding_power(:div), do: {11, 12}
  def binding_power(:floordiv), do: {11, 12}
  def binding_power(:mod), do: {11, 12}

  # Unary operators
  def binding_power(:not), do: {13, 14}
  def binding_power(:neg), do: {13, 14}
  def binding_power(:len), do: {13, 14}

  # Power (right associative)
  def binding_power(:pow), do: {16, 15}

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
  def prefix_binding_power(:not), do: 14
  # Between mult (11) and power (16)
  def prefix_binding_power(:sub), do: 13
  def prefix_binding_power(:len), do: 14
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
  def token_to_binop(_), do: nil

  @doc """
  Maps token operators to AST unary operators.
  """
  @spec token_to_unop(atom()) :: Expr.UnOp.op() | nil
  def token_to_unop(:not), do: :not
  def token_to_unop(:sub), do: :neg
  def token_to_unop(:len), do: :len
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
