defmodule BranchedLLM.E2E.ToolCallsTest do
  @moduledoc """
  E2E tests for tool call handling — execution, unknown tools,
  failing tools, usage limits, and non-schema __structured_output__.
  """
  use BranchedLLM.E2E.TestCase, async: false

  describe "tool calls" do
    @tag timeout: 60_000
    test "executes a tool call and returns the follow-up answer", %{
      mode: mode,
      bypass: bypass
    } do
      calculator =
        ReqLLM.Tool.new!(
          name: "calculator",
          description: "Evaluates math",
          parameter_schema: %{
            type: "object",
            properties: %{expression: %{type: "string"}},
            required: ["expression"]
          },
          callback: fn %{"expression" => expr} ->
            {result, _} = Code.eval_string(expr)
            {:ok, to_string(result)}
          end
        )

      if mode == :bypass do
        tc = %{
          "id" => "call_1",
          "name" => "calculator",
          "arguments" => Jason.encode!(%{"expression" => "2 + 2"})
        }

        call_count = :counters.new(1, [])

        expect_sse_fn(bypass, fn _conn ->
          :counters.add(call_count, 1, 1)

          :counters.get(call_count, 1)
          |> then(fn
            1 -> sse_tool_call([tc])
            _ -> sse_content(["4"])
          end)
        end)
      end

      events =
        collect_events(
          default_params(
            message: live_message("What is 2 + 2? Use the calculator tool."),
            llm_tools: [calculator]
          ),
          event_timeout()
        )

      assert find_event(events, :llm_tool_called)

      case mode do
        :bypass ->
          assert {:llm_end, "test", "4"} = find_event(events, :llm_end)

        :live ->
          assert find_event(events, :llm_end)
      end
    end

    @tag :bypass_only
    test "tool call with unknown tool — adds tool-not-found error to context", %{
      bypass: bypass
    } do
      dummy_tool =
        ReqLLM.Tool.new!(
          name: "some_other_tool",
          description: "Not the one being called",
          parameter_schema: %{type: "object", properties: %{}},
          callback: fn _ -> {:ok, "noop"} end
        )

      tc = %{
        "id" => "call_unknown",
        "name" => "nonexistent_tool",
        "arguments" => "{}"
      }

      call_count = :counters.new(1, [])

      expect_sse_fn(bypass, fn _conn ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 -> sse_tool_call([tc])
          _ -> sse_content(["I don't have that tool"])
        end
      end)

      events = collect_events(default_params(llm_tools: [dummy_tool]), event_timeout())

      assert find_event(events, :llm_tool_called)
      assert find_event(events, :llm_end)
    end

    @tag :bypass_only
    test "tool call with failing tool — adds tool-execution error to context", %{
      bypass: bypass
    } do
      broken_tool =
        ReqLLM.Tool.new!(
          name: "broken_tool",
          description: "Always fails",
          parameter_schema: %{
            type: "object",
            properties: %{input: %{type: "string"}},
            required: ["input"]
          },
          callback: fn _args -> {:error, "something went wrong"} end
        )

      tc = %{
        "id" => "call_broken",
        "name" => "broken_tool",
        "arguments" => Jason.encode!(%{"input" => "test"})
      }

      call_count = :counters.new(1, [])

      expect_sse_fn(bypass, fn _conn ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 -> sse_tool_call([tc])
          _ -> sse_content(["The tool failed but I tried"])
        end
      end)

      events = collect_events(default_params(llm_tools: [broken_tool]), event_timeout())

      assert find_event(events, :llm_tool_called)
      assert find_event(events, :llm_end)
    end

    @tag :bypass_only
    test "tool usage limit reached — tool returns limit message", %{bypass: bypass} do
      calculator =
        ReqLLM.Tool.new!(
          name: "calculator",
          description: "Evaluates math",
          parameter_schema: %{
            type: "object",
            properties: %{expression: %{type: "string"}},
            required: ["expression"]
          },
          callback: fn %{"expression" => expr} ->
            {result, _} = Code.eval_string(expr)
            {:ok, to_string(result)}
          end
        )

      tc = %{
        "id" => "call_limited",
        "name" => "calculator",
        "arguments" => Jason.encode!(%{"expression" => "1+1"})
      }

      call_count = :counters.new(1, [])

      expect_sse_fn(bypass, fn _conn ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 -> sse_tool_call([tc])
          _ -> sse_content(["done"])
        end
      end)

      params =
        default_params(llm_tools: [calculator])
        |> Map.put(:tool_usage_counts, %{calculator: 10})

      events = collect_events(params, event_timeout())

      assert find_event(events, :llm_tool_called)
      assert find_event(events, :llm_end)
    end

    @tag :bypass_only
    test "non-schema __structured_output__ tool call emits llm_end with args_map", %{
      bypass: bypass
    } do
      dummy_tool =
        ReqLLM.Tool.new!(
          name: "noop",
          description: "No-op",
          parameter_schema: %{type: "object", properties: %{}},
          callback: fn _ -> {:ok, "noop"} end
        )

      tc = %{
        "id" => "call_structured",
        "name" => "__structured_output__",
        "arguments" => Jason.encode!(%{"answer" => "42"})
      }

      expect_sse(bypass, sse_tool_call([tc]))

      events = collect_events(default_params(llm_tools: [dummy_tool]), event_timeout())

      assert {:llm_end, "test", result} = find_event(events, :llm_end)
      assert is_map(result)
      assert result["answer"] == "42"
    end
  end
end
