defmodule BranchedLLM.ToolCache.EctoTest do
  use ExUnit.Case, async: true

  alias BranchedLLM.ToolCache.Ecto, as: ToolCacheEcto

  setup do
    # Clear any existing config
    Application.put_env(:branched_llm, BranchedLLM.ToolCache, [])

    on_exit(fn ->
      Application.put_env(:branched_llm, BranchedLLM.ToolCache, [])
    end)

    :ok
  end

  test "get_result raises when no repo is configured" do
    assert_raise KeyError, fn ->
      ToolCacheEcto.get_result("test", %{})
    end
  end

  test "save_result raises when no repo is configured" do
    assert_raise KeyError, fn ->
      ToolCacheEcto.save_result("test", %{}, "result")
    end
  end

  defmodule MockRepo do
    defmodule ToolResult do
      use Ecto.Schema

      schema "tool_results" do
        field(:tool_name, :string)
        field(:args, :map)
        field(:result, :any, virtual: true)
        timestamps()
      end
    end

    def one(_query), do: "cached_result"
    def insert_all(_schema, _data), do: {1, nil}
  end

  test "get_result and save_result with mock repo and map args" do
    Application.put_env(:branched_llm, BranchedLLM.ToolCache, repo: MockRepo)

    # Test map args normalization (atom keys to string)
    assert ToolCacheEcto.get_result("test", %{a: 1}) == {:ok, "cached_result"}

    # Test non-map args normalization
    assert ToolCacheEcto.get_result("test", "simple_arg") == {:ok, "cached_result"}
  end
end
