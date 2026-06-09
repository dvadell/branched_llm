defmodule BranchedLLM.E2E.StreamingTest do
  @moduledoc """
  E2E tests for basic streaming behavior — text content delivery,
  event emission (llm_chunk, llm_end, llm_metadata, update_tool_usage_counts).
  """
  use BranchedLLM.E2E.TestCase, async: false

  describe "streaming" do
    @tag timeout: 60_000
    test "streams text content and emits llm_end", %{mode: mode, bypass: bypass} do
      maybe_expect_sse(%{mode: mode, bypass: bypass}, sse_content(["Hello", " world"]))

      params = default_params(message: live_message("Say exactly: Hello world"))
      events = collect_events(params, event_timeout())

      assert find_event(events, :llm_chunk)

      case mode do
        :bypass ->
          assert {:llm_end, "test", "Hello world"} = find_event(events, :llm_end)

        :live ->
          assert find_event(events, :llm_end)
      end

      assert find_event(events, :llm_metadata)
    end

    @tag timeout: 60_000
    test "emits update_tool_usage_counts event", %{mode: mode, bypass: bypass} do
      maybe_expect_sse(%{mode: mode, bypass: bypass}, sse_content(["done"]))

      params = default_params(message: live_message("Say: done"))
      events = collect_events(params, event_timeout())

      assert find_event(events, :update_tool_usage_counts)
    end
  end
end
