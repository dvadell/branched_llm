defmodule BranchedLLM.UUIDTest do
  use ExUnit.Case

  test "uses Uniq.UUID when available" do
    result = BranchedLLM.UUID.generate(fn _ -> true end)
    # assert UUID v4 format
    assert result =~ ~r/^[0-9a-f-]{36}$/
  end

  test "uses Ecto.UUID when Uniq.UUID is not available" do
    result = BranchedLLM.UUID.generate(fn
      Uniq.UUID -> false
      _ -> true
    end)
    assert result =~ ~r/^[0-9a-f-]{36}$/
  end

  test "falls back to crypto when no UUID library is available" do
    result = BranchedLLM.UUID.generate(fn _ -> false end)
    assert result =~ ~r/^[0-9a-f]{32}$/
  end
end
