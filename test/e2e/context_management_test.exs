defmodule BranchedLLM.E2E.ContextManagementTest do
  @moduledoc """
  E2E tests for context management — pruning, sliding window,
  percentage, summarize strategies, and custom trim callbacks
  (2-tuple, 3-tuple, 1-arity function, and failing callbacks).
  """
  use BranchedLLM.E2E.TestCase, async: false

  describe "context management — bypass only" do
    @tag :bypass_only
    test "trims context via Prune strategy when max_tokens is exceeded", %{bypass: bypass} do
      Application.put_env(:branched_llm, :max_tokens, 10)
      expect_sse(bypass, sse_content(["ok"]))

      context =
        Context.new([Context.system("You are a helpful assistant.")])
        |> Context.append(Context.user("First message with enough text to exceed tokens"))
        |> Context.append(Context.assistant("First response with enough text"))
        |> Context.append(Context.user("Second message with enough text"))

      params = %{
        llm_context: context,
        llm_tools: [],
        chat_mod: BranchedLLM.Chat,
        tool_usage_counts: %{},
        branch_id: "test"
      }

      events = collect_events(params, event_timeout())
      assert find_event(events, :llm_end)
    after
      Application.delete_env(:branched_llm, :max_tokens)
    end

    @tag :bypass_only
    test "trims context via SlidingWindow strategy when configured", %{bypass: bypass} do
      Application.put_env(:branched_llm, :max_tokens, 10)

      Application.put_env(
        :branched_llm,
        :trim_callback,
        {BranchedLLM.ContextManager.Strategy.SlidingWindow, :trim, [keep: 1]}
      )

      expect_sse(bypass, sse_content(["ok"]))

      context =
        Context.new([Context.system("You are a helpful assistant.")])
        |> Context.append(Context.user("First message"))
        |> Context.append(Context.assistant("First response"))
        |> Context.append(Context.user("Second message"))
        |> Context.append(Context.assistant("Second response"))
        |> Context.append(Context.user("Third message"))

      params = %{
        llm_context: context,
        llm_tools: [],
        chat_mod: BranchedLLM.Chat,
        tool_usage_counts: %{},
        branch_id: "test"
      }

      events = collect_events(params, event_timeout())
      assert find_event(events, :llm_end)
    after
      Application.delete_env(:branched_llm, :max_tokens)
      Application.delete_env(:branched_llm, :trim_callback)
    end

    @tag :bypass_only
    test "trims context via Percentage strategy when configured", %{bypass: bypass} do
      Application.put_env(:branched_llm, :max_tokens, 10)

      Application.put_env(
        :branched_llm,
        :trim_callback,
        {BranchedLLM.ContextManager.Strategy.Percentage, :trim, [retain: 0.5]}
      )

      expect_sse(bypass, sse_content(["ok"]))

      context =
        Context.new([Context.system("You are a helpful assistant.")])
        |> Context.append(Context.user("First message with substantial text content"))
        |> Context.append(Context.assistant("First response with substantial text content"))
        |> Context.append(Context.user("Second message with substantial text content"))
        |> Context.append(Context.assistant("Second response with substantial text content"))

      params = %{
        llm_context: context,
        llm_tools: [],
        chat_mod: BranchedLLM.Chat,
        tool_usage_counts: %{},
        branch_id: "test"
      }

      events = collect_events(params, event_timeout())
      assert find_event(events, :llm_end)
    after
      Application.delete_env(:branched_llm, :max_tokens)
      Application.delete_env(:branched_llm, :trim_callback)
    end

    @tag :bypass_only
    test "trims context via Summarize strategy when configured", %{bypass: bypass} do
      Application.put_env(:branched_llm, :max_tokens, 10)

      Application.put_env(
        :branched_llm,
        :trim_callback,
        {BranchedLLM.ContextManager.Strategy.Summarize, :trim, [recent_count: 2]}
      )

      expect_sse(bypass, sse_content(["ok"]))

      context =
        Context.new([Context.system("You are a helpful assistant.")])
        |> Context.append(Context.user("First message to be summarized"))
        |> Context.append(Context.assistant("First response to be summarized"))
        |> Context.append(Context.user("Recent message kept intact"))
        |> Context.append(Context.assistant("Recent response kept intact"))

      params = %{
        llm_context: context,
        llm_tools: [],
        chat_mod: BranchedLLM.Chat,
        tool_usage_counts: %{},
        branch_id: "test"
      }

      events = collect_events(params, event_timeout())
      assert find_event(events, :llm_end)
    after
      Application.delete_env(:branched_llm, :max_tokens)
      Application.delete_env(:branched_llm, :trim_callback)
    end

    @tag :bypass_only
    test "trims context via 2-tuple callback when configured", %{bypass: bypass} do
      Application.put_env(:branched_llm, :max_tokens, 10)

      Application.put_env(
        :branched_llm,
        :trim_callback,
        {BranchedLLM.ContextManager.Strategy.SlidingWindow, :trim}
      )

      expect_sse(bypass, sse_content(["ok"]))

      context =
        Context.new([Context.system("You are a helpful assistant.")])
        |> Context.append(Context.user("First message"))
        |> Context.append(Context.assistant("First response"))
        |> Context.append(Context.user("Second message"))

      params = %{
        llm_context: context,
        llm_tools: [],
        chat_mod: BranchedLLM.Chat,
        tool_usage_counts: %{},
        branch_id: "test"
      }

      events = collect_events(params, event_timeout())
      assert find_event(events, :llm_end)
    after
      Application.delete_env(:branched_llm, :max_tokens)
      Application.delete_env(:branched_llm, :trim_callback)
    end

    @tag :bypass_only
    test "trims context via 1-arity function callback when configured", %{bypass: bypass} do
      Application.put_env(:branched_llm, :max_tokens, 10)

      Application.put_env(
        :branched_llm,
        :trim_callback,
        fn ctx -> SlidingWindow.trim(ctx, keep: 1) end
      )

      expect_sse(bypass, sse_content(["ok"]))

      context =
        Context.new([Context.system("You are a helpful assistant.")])
        |> Context.append(Context.user("First message"))
        |> Context.append(Context.assistant("First response"))
        |> Context.append(Context.user("Second message"))

      params = %{
        llm_context: context,
        llm_tools: [],
        chat_mod: BranchedLLM.Chat,
        tool_usage_counts: %{},
        branch_id: "test"
      }

      events = collect_events(params, event_timeout())
      assert find_event(events, :llm_end)
    after
      Application.delete_env(:branched_llm, :max_tokens)
      Application.delete_env(:branched_llm, :trim_callback)
    end

    @tag :bypass_only
    test "trims context with failing 3-tuple callback — falls back to pruning", %{
      bypass: bypass
    } do
      Application.put_env(:branched_llm, :max_tokens, 10)
      Application.put_env(:branched_llm, :trim_callback, {Kernel, :apply, [[:boom]]})

      _log =
        capture_log(fn ->
          expect_sse(bypass, sse_content(["ok"]))

          context =
            Context.new([Context.system("You are a helpful assistant.")])
            |> Context.append(Context.user("First message"))
            |> Context.append(Context.assistant("First response"))
            |> Context.append(Context.user("Second message"))

          params = %{
            llm_context: context,
            llm_tools: [],
            chat_mod: BranchedLLM.Chat,
            tool_usage_counts: %{},
            branch_id: "test"
          }

          events = collect_events(params, event_timeout())
          assert find_event(events, :llm_end)
        end)
    after
      Application.delete_env(:branched_llm, :max_tokens)
      Application.delete_env(:branched_llm, :trim_callback)
    end

    @tag :bypass_only
    test "trims context with failing 2-tuple callback — falls back to pruning", %{
      bypass: bypass
    } do
      Application.put_env(:branched_llm, :max_tokens, 10)
      Application.put_env(:branched_llm, :trim_callback, {Kernel, :apply})

      _log =
        capture_log(fn ->
          expect_sse(bypass, sse_content(["ok"]))

          context =
            Context.new([Context.system("You are a helpful assistant.")])
            |> Context.append(Context.user("First message"))
            |> Context.append(Context.assistant("First response"))
            |> Context.append(Context.user("Second message"))

          params = %{
            llm_context: context,
            llm_tools: [],
            chat_mod: BranchedLLM.Chat,
            tool_usage_counts: %{},
            branch_id: "test"
          }

          events = collect_events(params, event_timeout())
          assert find_event(events, :llm_end)
        end)
    after
      Application.delete_env(:branched_llm, :max_tokens)
      Application.delete_env(:branched_llm, :trim_callback)
    end

    @tag :bypass_only
    test "trims context with failing 1-arity function callback — falls back to pruning", %{
      bypass: bypass
    } do
      Application.put_env(:branched_llm, :max_tokens, 10)
      Application.put_env(:branched_llm, :trim_callback, fn _ctx -> raise "boom" end)

      _log =
        capture_log(fn ->
          expect_sse(bypass, sse_content(["ok"]))

          context =
            Context.new([Context.system("You are a helpful assistant.")])
            |> Context.append(Context.user("First message"))
            |> Context.append(Context.assistant("First response"))
            |> Context.append(Context.user("Second message"))

          params = %{
            llm_context: context,
            llm_tools: [],
            chat_mod: BranchedLLM.Chat,
            tool_usage_counts: %{},
            branch_id: "test"
          }

          events = collect_events(params, event_timeout())
          assert find_event(events, :llm_end)
        end)
    after
      Application.delete_env(:branched_llm, :max_tokens)
      Application.delete_env(:branched_llm, :trim_callback)
    end
  end
end
