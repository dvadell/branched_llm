defmodule BranchedLLM.OrchestratorTest do
  use ExUnit.Case, async: false
  import Mox
  alias BranchedLLM.ChatOrchestrator
  alias ReqLLM.Context

  setup :set_mox_from_context

  defp make_context do
    Context.new([Context.system("System")])
  end

  defp stream_response(tokens) do
    stream = Stream.map(tokens, &%{text: &1, type: :content})

    %ReqLLM.StreamResponse{
      stream: stream,
      context: Context.new([]),
      model: "gpt-mock",
      cancel: fn -> :ok end,
      metadata_task: Task.async(fn -> %{} end)
    }
  end

  defp context_builder(content) do
    Context.new([Context.assistant(content)])
  end

  describe "run/1 sends chunks and end to caller_pid" do
    test "basic streaming" do
      tokens = ["Hello", " world"]

      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _msg, _ctx, _opts ->
        {:ok, stream_response(tokens), &context_builder/1, []}
      end)

      params = %{
        message: "Hi",
        llm_context: make_context(),
        caller_pid: self(),
        llm_tools: [],
        chat_mod: BranchedLLM.ChatMock,
        tool_usage_counts: %{},
        branch_id: "main"
      }

      {:ok, _pid} = ChatOrchestrator.run(params)

      assert_receive {:llm_chunk, "main", "Hello"}, 500
      assert_receive {:llm_chunk, "main", " world"}, 500
      assert_receive {:llm_end, "main", _builder}, 500
      assert_receive {:update_tool_usage_counts, _}, 500
    end
  end

  describe "run/1 handles errors" do
    test "returns error on failure" do
      stub(BranchedLLM.ChatMock, :send_message_stream, fn _msg, _ctx, _opts ->
        {:error, "Connection failed"}
      end)

      params = %{
        message: "Hi",
        llm_context: make_context(),
        caller_pid: self(),
        llm_tools: [],
        chat_mod: BranchedLLM.ChatMock,
        tool_usage_counts: %{},
        branch_id: "main"
      }

      {:ok, _pid} = ChatOrchestrator.run(params)

      # Retry with 100ms backoff x 10 = ~1s total, so wait longer
      assert_receive {:llm_error, "main", _error}, 2000
    end
  end

  describe "run/1 passes llm_tools and tool_usage_counts" do
    test "tools are passed through" do
      call_count = :counters.new(1, [])

      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _msg, _ctx, opts ->
        :counters.add(call_count, 1, 1)
        assert Keyword.has_key?(opts, :tools)
        {:ok, stream_response(["response"]), &context_builder/1, []}
      end)

      params = %{
        message: "Hi",
        llm_context: make_context(),
        caller_pid: self(),
        llm_tools: [%{name: "test_tool"}],
        chat_mod: BranchedLLM.ChatMock,
        tool_usage_counts: %{test_tool: 0},
        branch_id: "main"
      }

      {:ok, _pid} = ChatOrchestrator.run(params)

      assert_receive {:llm_chunk, "main", "response"}, 500
      assert_receive {:llm_end, "main", _builder}, 500
    end
  end

  describe "run/1 handles tool calls and recurses" do
    test "executes tool and returns final answer" do
      tool_call = ReqLLM.ToolCall.new("call_1", "get_weather", ~s({"location": "NYC"}))

      # First call returns tool_calls
      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _msg, _ctx, _opts ->
        {:ok, stream_response([]), &context_builder/1, [tool_call]}
      end)

      # Mock execute_tool for the tool call
      expect(BranchedLLM.ChatMock, :execute_tool, 1, fn _tool, _args -> {:ok, "Sunny"} end)

      # Second call (after recursion) returns text
      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _msg, _ctx, _opts ->
        {:ok, stream_response(["Final answer"]), &context_builder/1, []}
      end)

      params = %{
        message: "Weather?",
        llm_context: make_context(),
        caller_pid: self(),
        llm_tools: [%{name: "get_weather"}],
        chat_mod: BranchedLLM.ChatMock,
        tool_usage_counts: %{get_weather: 0},
        branch_id: "main"
      }

      {:ok, _pid} = ChatOrchestrator.run(params)

      assert_receive {:llm_status, "main", _status}, 500
      assert_receive {:update_tool_usage_counts, %{get_weather: 1}}, 500
      assert_receive {:llm_chunk, "main", "Final answer"}, 500
      assert_receive {:llm_end, "main", _builder}, 500
    end
  end

  describe "run/1 enforces tool usage limits" do
    test "skips tool execution when limit reached" do
      tool_call = ReqLLM.ToolCall.new("call_1", "limited_tool", ~s({}))

      # First call returns tool_calls
      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _msg, _ctx, _opts ->
        {:ok, stream_response([]), &context_builder/1, [tool_call]}
      end)

      # No execute_tool call expected (limit reached), second call returns text
      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _msg, _ctx, _opts ->
        {:ok, stream_response(["done"]), &context_builder/1, []}
      end)

      params = %{
        message: "Use tool",
        llm_context: make_context(),
        caller_pid: self(),
        llm_tools: [%{name: "limited_tool"}],
        chat_mod: BranchedLLM.ChatMock,
        tool_usage_counts: %{limited_tool: 10},
        branch_id: "main"
      }

      {:ok, _pid} = ChatOrchestrator.run(params)

      assert_receive {:update_tool_usage_counts, _}, 2000
      assert_receive {:llm_chunk, "main", "done"}, 500
      assert_receive {:llm_end, "main", _builder}, 500
    end
  end

  describe "run/1 handles empty stream" do
    test "retries when stream has no tokens (treated as error)" do
      # When process_stream returns false (no chunks), it's an error
      # which triggers retries. After 10 retries, it sends llm_error.
      stub(BranchedLLM.ChatMock, :send_message_stream, fn _msg, _ctx, _opts ->
        {:ok, stream_response([]), &context_builder/1, []}
      end)

      params = %{
        message: "Hi",
        llm_context: make_context(),
        caller_pid: self(),
        llm_tools: [],
        chat_mod: BranchedLLM.ChatMock,
        tool_usage_counts: %{},
        branch_id: "main"
      }

      {:ok, _pid} = ChatOrchestrator.run(params)

      # After retries, we get an error
      assert_receive {:llm_error, "main", _error}, 2000
    end
  end

  describe "run/1 tool call limit with all tools at limit" do
    test "appends tool call results when all tools are at limit" do
      tool_call = ReqLLM.ToolCall.new("call_1", "full_tool", ~s({}))

      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _msg, _ctx, _opts ->
        {:ok, stream_response([]), &context_builder/1, [tool_call]}
      end)

      # All tools at limit, no execute_tool call, second call returns text
      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _msg, _ctx, _opts ->
        {:ok, stream_response(["answer"]), &context_builder/1, []}
      end)

      params = %{
        message: "Test",
        llm_context: make_context(),
        caller_pid: self(),
        llm_tools: [%{name: "full_tool"}],
        chat_mod: BranchedLLM.ChatMock,
        tool_usage_counts: %{full_tool: 10},
        branch_id: "main"
      }

      {:ok, _pid} = ChatOrchestrator.run(params)

      assert_receive {:update_tool_usage_counts, _}, 2000
      assert_receive {:llm_chunk, "main", "answer"}, 500
      assert_receive {:llm_end, "main", _builder}, 500
    end
  end

  describe "run/1 handles exceptions" do
    test "formats exception and sends error" do
      stub(BranchedLLM.ChatMock, :send_message_stream, fn _msg, _ctx, _opts ->
        raise RuntimeError, "boom"
      end)

      params = %{
        message: "Hi",
        llm_context: make_context(),
        caller_pid: self(),
        llm_tools: [],
        chat_mod: BranchedLLM.ChatMock,
        tool_usage_counts: %{},
        branch_id: "main"
      }

      {:ok, _pid} = ChatOrchestrator.run(params)

      # Retries with exception, then sends error
      assert_receive {:llm_error, "main", _error}, 2000
    end
  end
end
