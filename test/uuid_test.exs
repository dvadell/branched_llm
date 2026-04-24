defmodule BranchedLLM.UUIDTest do
  use ExUnit.Case, async: true
  alias BranchedLLM.UUID

  test "generate returns a valid string" do
    uuid = UUID.generate()
    assert is_binary(uuid)
    # Check if it looks like a UUID (8-4-4-4-12) or a 32-char hex string
    assert String.length(uuid) == 36 or String.length(uuid) == 32
  end
end
