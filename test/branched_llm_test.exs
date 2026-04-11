defmodule BranchedLlmTest do
  use ExUnit.Case
  doctest BranchedLlm

  test "greets the world" do
    assert BranchedLlm.hello() == :world
  end
end
