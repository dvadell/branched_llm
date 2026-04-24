defmodule BranchedLLM.ToolCache.InMemoryTest do
  use ExUnit.Case, async: true
  alias BranchedLLM.ToolCache.InMemory

  test "get_result always returns :error" do
    assert InMemory.get_result("test", %{}) == :error
  end

  test "save_result always returns :ok" do
    assert InMemory.save_result("test", %{}, "result") == :ok
  end
end
