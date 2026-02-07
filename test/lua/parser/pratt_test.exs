defmodule Lua.Parser.PrattTest do
  use ExUnit.Case, async: true
  alias Lua.Parser.Pratt

  describe "binding_power/1" do
    test "returns correct binding power for or operator" do
      assert {1, 2} = Pratt.binding_power(:or)
    end

    test "returns correct binding power for and operator" do
      assert {3, 4} = Pratt.binding_power(:and)
    end

    test "returns correct binding power for comparison operators" do
      assert {5, 6} = Pratt.binding_power(:lt)
      assert {5, 6} = Pratt.binding_power(:gt)
      assert {5, 6} = Pratt.binding_power(:le)
      assert {5, 6} = Pratt.binding_power(:ge)
      assert {5, 6} = Pratt.binding_power(:ne)
      assert {5, 6} = Pratt.binding_power(:eq)
    end

    test "returns correct binding power for bitwise operators" do
      assert {7, 8} = Pratt.binding_power(:bor)
      assert {9, 10} = Pratt.binding_power(:bxor)
      assert {11, 12} = Pratt.binding_power(:band)
      assert {13, 14} = Pratt.binding_power(:shl)
      assert {13, 14} = Pratt.binding_power(:shr)
    end

    test "returns correct binding power for concat operator (right associative)" do
      assert {15, 14} = Pratt.binding_power(:concat)
    end

    test "returns correct binding power for additive operators" do
      assert {17, 18} = Pratt.binding_power(:add)
      assert {17, 18} = Pratt.binding_power(:sub)
    end

    test "returns correct binding power for multiplicative operators" do
      assert {19, 20} = Pratt.binding_power(:mul)
      assert {19, 20} = Pratt.binding_power(:div)
      assert {19, 20} = Pratt.binding_power(:floordiv)
      assert {19, 20} = Pratt.binding_power(:mod)
    end

    test "returns correct binding power for unary operators (should not be used as binary)" do
      # These are unary operators, but the function includes them for completeness
      # They should not be used as binary operators in practice
      assert {21, 22} = Pratt.binding_power(:not)
      assert {21, 22} = Pratt.binding_power(:neg)
      assert {21, 22} = Pratt.binding_power(:len)
    end

    test "returns correct binding power for power operator (right associative)" do
      assert {24, 23} = Pratt.binding_power(:pow)
    end

    test "returns nil for non-operators" do
      assert nil == Pratt.binding_power(:invalid)
      assert nil == Pratt.binding_power(:lparen)
      assert nil == Pratt.binding_power(:rparen)
      assert nil == Pratt.binding_power(:identifier)
    end
  end

  describe "prefix_binding_power/1" do
    test "returns correct binding power for not operator" do
      assert 22 = Pratt.prefix_binding_power(:not)
    end

    test "returns correct binding power for unary minus (sub)" do
      assert 21 = Pratt.prefix_binding_power(:sub)
    end

    test "returns correct binding power for length operator" do
      assert 22 = Pratt.prefix_binding_power(:len)
    end

    test "returns correct binding power for bitwise not" do
      assert 22 = Pratt.prefix_binding_power(:bxor)
    end

    test "returns nil for non-prefix operators" do
      assert nil == Pratt.prefix_binding_power(:add)
      assert nil == Pratt.prefix_binding_power(:mul)
      assert nil == Pratt.prefix_binding_power(:invalid)
    end
  end

  describe "token_to_binop/1" do
    test "maps logical operators" do
      assert :or = Pratt.token_to_binop(:or)
      assert :and = Pratt.token_to_binop(:and)
    end

    test "maps comparison operators" do
      assert :lt = Pratt.token_to_binop(:lt)
      assert :gt = Pratt.token_to_binop(:gt)
      assert :le = Pratt.token_to_binop(:le)
      assert :ge = Pratt.token_to_binop(:ge)
      assert :ne = Pratt.token_to_binop(:ne)
      assert :eq = Pratt.token_to_binop(:eq)
    end

    test "maps string concatenation operator" do
      assert :concat = Pratt.token_to_binop(:concat)
    end

    test "maps arithmetic operators" do
      assert :add = Pratt.token_to_binop(:add)
      assert :sub = Pratt.token_to_binop(:sub)
      assert :mul = Pratt.token_to_binop(:mul)
      assert :div = Pratt.token_to_binop(:div)
      assert :floordiv = Pratt.token_to_binop(:floordiv)
      assert :mod = Pratt.token_to_binop(:mod)
      assert :pow = Pratt.token_to_binop(:pow)
    end

    test "maps bitwise operators" do
      assert :band = Pratt.token_to_binop(:band)
      assert :bor = Pratt.token_to_binop(:bor)
      assert :bxor = Pratt.token_to_binop(:bxor)
      assert :shl = Pratt.token_to_binop(:shl)
      assert :shr = Pratt.token_to_binop(:shr)
    end

    test "returns nil for non-binary operators" do
      assert nil == Pratt.token_to_binop(:not)
      assert nil == Pratt.token_to_binop(:len)
      assert nil == Pratt.token_to_binop(:invalid)
    end
  end

  describe "token_to_unop/1" do
    test "maps unary operators" do
      assert :not = Pratt.token_to_unop(:not)
      assert :neg = Pratt.token_to_unop(:sub)
      assert :len = Pratt.token_to_unop(:len)
      assert :bnot = Pratt.token_to_unop(:bxor)
    end

    test "returns nil for non-unary operators" do
      assert nil == Pratt.token_to_unop(:add)
      assert nil == Pratt.token_to_unop(:mul)
      assert nil == Pratt.token_to_unop(:or)
      assert nil == Pratt.token_to_unop(:invalid)
    end
  end

  describe "is_binary_op?/1" do
    test "returns true for binary operators" do
      assert Pratt.is_binary_op?(:or)
      assert Pratt.is_binary_op?(:and)
      assert Pratt.is_binary_op?(:lt)
      assert Pratt.is_binary_op?(:gt)
      assert Pratt.is_binary_op?(:le)
      assert Pratt.is_binary_op?(:ge)
      assert Pratt.is_binary_op?(:ne)
      assert Pratt.is_binary_op?(:eq)
      assert Pratt.is_binary_op?(:concat)
      assert Pratt.is_binary_op?(:add)
      assert Pratt.is_binary_op?(:sub)
      assert Pratt.is_binary_op?(:mul)
      assert Pratt.is_binary_op?(:div)
      assert Pratt.is_binary_op?(:floordiv)
      assert Pratt.is_binary_op?(:mod)
      assert Pratt.is_binary_op?(:pow)
      assert Pratt.is_binary_op?(:band)
      assert Pratt.is_binary_op?(:bor)
      assert Pratt.is_binary_op?(:bxor)
      assert Pratt.is_binary_op?(:shl)
      assert Pratt.is_binary_op?(:shr)
    end

    test "returns false for non-binary operators" do
      refute Pratt.is_binary_op?(:invalid)
      refute Pratt.is_binary_op?(:lparen)
      refute Pratt.is_binary_op?(:identifier)
    end
  end

  describe "is_prefix_op?/1" do
    test "returns true for prefix operators" do
      assert Pratt.is_prefix_op?(:not)
      assert Pratt.is_prefix_op?(:sub)
      assert Pratt.is_prefix_op?(:len)
      assert Pratt.is_prefix_op?(:bxor)
    end

    test "returns false for non-prefix operators" do
      refute Pratt.is_prefix_op?(:add)
      refute Pratt.is_prefix_op?(:mul)
      refute Pratt.is_prefix_op?(:or)
      refute Pratt.is_prefix_op?(:invalid)
    end
  end

  describe "operator precedence correctness" do
    test "logical operators have lowest precedence" do
      {or_left, _} = Pratt.binding_power(:or)
      {and_left, _} = Pratt.binding_power(:and)
      {lt_left, _} = Pratt.binding_power(:lt)

      assert or_left < and_left
      assert and_left < lt_left
    end

    test "comparison operators have same precedence" do
      {lt_left, _} = Pratt.binding_power(:lt)
      {gt_left, _} = Pratt.binding_power(:gt)
      {le_left, _} = Pratt.binding_power(:le)
      {ge_left, _} = Pratt.binding_power(:ge)
      {ne_left, _} = Pratt.binding_power(:ne)
      {eq_left, _} = Pratt.binding_power(:eq)

      assert lt_left == gt_left
      assert lt_left == le_left
      assert lt_left == ge_left
      assert lt_left == ne_left
      assert lt_left == eq_left
    end

    test "concat is right associative (left_bp > right_bp)" do
      {left_bp, right_bp} = Pratt.binding_power(:concat)
      assert left_bp > right_bp
    end

    test "power is right associative (left_bp > right_bp)" do
      {left_bp, right_bp} = Pratt.binding_power(:pow)
      assert left_bp > right_bp
    end

    test "addition is left associative (left_bp >= right_bp)" do
      {left_bp, right_bp} = Pratt.binding_power(:add)
      assert left_bp < right_bp
    end

    test "multiplication has higher precedence than addition" do
      {add_left, _} = Pratt.binding_power(:add)
      {mul_left, _} = Pratt.binding_power(:mul)

      assert mul_left > add_left
    end

    test "all multiplicative operators have same precedence" do
      {mul_left, _} = Pratt.binding_power(:mul)
      {div_left, _} = Pratt.binding_power(:div)
      {floordiv_left, _} = Pratt.binding_power(:floordiv)
      {mod_left, _} = Pratt.binding_power(:mod)

      assert mul_left == div_left
      assert mul_left == floordiv_left
      assert mul_left == mod_left
    end

    test "unary operators have higher precedence than multiplication" do
      unary_bp = Pratt.prefix_binding_power(:sub)
      {mul_left, _} = Pratt.binding_power(:mul)

      assert unary_bp > mul_left
    end

    test "power has higher precedence than unary (special case)" do
      unary_bp = Pratt.prefix_binding_power(:sub)
      {pow_left, _} = Pratt.binding_power(:pow)

      # Unary minus has lower precedence than power's left binding
      # This ensures -2^3 parses as -(2^3)
      assert unary_bp < pow_left
    end

    test "not and len have same prefix binding power" do
      not_bp = Pratt.prefix_binding_power(:not)
      len_bp = Pratt.prefix_binding_power(:len)

      assert not_bp == len_bp
    end
  end
end
