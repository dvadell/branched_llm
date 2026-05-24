defmodule BranchedLLM.OrchestratorTest do
  use ExUnit.Case, async: false
  import Mox

  alias BranchedLLM.ChatOrchestrator
  alias ReqLLM.Context
  alias ReqLLM.StreamResponse.MetadataHandle

  setup :set_mox_from_context

  defp make_context do
    Context.new([Context.system("System")])
  end

  defp stream_response(tokens) do
    stream = Stream.map(tokens, &%{text: &1, type: :content})

    {:ok, metadata_handle} = MetadataHandle.start_link(fn -> %{} end)

    %ReqLLM.StreamResponse{
      stream: stream,
      context: Context.new([]),
      model: "gpt-mock",
      cancel: fn -> :ok end,
      metadata_handle: metadata_handle
    }
  end

  defp context_builder(content) do
    Context.new([Context.assistant(content)])
  end

  describe "run/1 sends chunks and end through on_event" do
    test "basic streaming" do
      tokens = ["Hello", " world"]

      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _msg, _ctx, _opts ->
        {:ok, stream_response(tokens), &context_builder/1, [], nil}
      end)

      pid = self()

      params = %{
        message: "Hi",
        llm_context: make_context(),
        on_event: fn event -> send(pid, event) end,
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

      pid = self()

      params = %{
        message: "Hi",
        llm_context: make_context(),
        on_event: fn event -> send(pid, event) end,
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
        {:ok, stream_response(["response"]), &context_builder/1, [], nil}
      end)

      pid = self()

      params = %{
        message: "Hi",
        llm_context: make_context(),
        on_event: fn event -> send(pid, event) end,
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
        {:ok, stream_response([]), &context_builder/1, [tool_call], nil}
      end)

      # Mock execute_tool for the tool call
      expect(BranchedLLM.ChatMock, :execute_tool, 1, fn _tool, _args ->
        {:ok, "Sunny"}
      end)

      # Second call (after recursion) returns text
      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _msg, _ctx, _opts ->
        {:ok, stream_response(["Final answer"]), &context_builder/1, [], nil}
      end)

      pid = self()

      params = %{
        message: "Weather?",
        llm_context: make_context(),
        on_event: fn event -> send(pid, event) end,
        llm_tools: [%{name: "get_weather"}],
        chat_mod: BranchedLLM.ChatMock,
        tool_usage_counts: %{get_weather: 0},
        branch_id: "main"
      }

      {:ok, _pid} = ChatOrchestrator.run(params)

      assert_receive {:llm_tool_called, "main",
                      %{id: "call_1", name: "get_weather", arguments: %{"location" => "NYC"}}},
                     500

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
        {:ok, stream_response([]), &context_builder/1, [tool_call], nil}
      end)

      # No execute_tool call expected (limit reached), second call returns text
      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _msg, _ctx, _opts ->
        {:ok, stream_response(["done"]), &context_builder/1, [], nil}
      end)

      pid = self()

      params = %{
        message: "Use tool",
        llm_context: make_context(),
        on_event: fn event -> send(pid, event) end,
        llm_tools: [%{name: "limited_tool"}],
        chat_mod: BranchedLLM.ChatMock,
        tool_usage_counts: %{limited_tool: 10},
        branch_id: "main"
      }

      {:ok, _pid} = ChatOrchestrator.run(params)

      assert_receive {:llm_tool_called, "main",
                      %{id: "call_1", name: "limited_tool", arguments: %{}}},
                     500

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
        {:ok, stream_response([]), &context_builder/1, [], nil}
      end)

      pid = self()

      params = %{
        message: "Hi",
        llm_context: make_context(),
        on_event: fn event -> send(pid, event) end,
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
        {:ok, stream_response([]), &context_builder/1, [tool_call], nil}
      end)

      # All tools at limit, no execute_tool call, second call returns text
      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _msg, _ctx, _opts ->
        {:ok, stream_response(["answer"]), &context_builder/1, [], nil}
      end)

      pid = self()

      params = %{
        message: "Test",
        llm_context: make_context(),
        on_event: fn event -> send(pid, event) end,
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

  describe "run/1 handles pre-consumed text" do
    test "emits pre-consumed text as chunks when present" do
      # When tools are present, classify/1 consumes the stream and provides
      # pre_consumed_text. This tests the process_text/5 path.
      tool_call = ReqLLM.ToolCall.new("call_1", "get_weather", ~s({"location": "NYC"}))

      # First call returns tool_calls with pre_consumed_text
      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _msg, _ctx, _opts ->
        {:ok, stream_response([]), &context_builder/1, [tool_call], "The weather is"}
      end)

      expect(BranchedLLM.ChatMock, :execute_tool, 1, fn _tool, _args ->
        {:ok, "Sunny"}
      end)

      # Second call (after recursion) returns text with pre_consumed_text
      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _msg, _ctx, _opts ->
        {:ok, stream_response([]), &context_builder/1, [], "Final answer"}
      end)

      pid = self()

      params = %{
        message: "Weather?",
        llm_context: make_context(),
        on_event: fn event -> send(pid, event) end,
        llm_tools: [%{name: "get_weather"}],
        chat_mod: BranchedLLM.ChatMock,
        tool_usage_counts: %{get_weather: 0},
        branch_id: "main"
      }

      {:ok, _pid} = ChatOrchestrator.run(params)

      assert_receive {:llm_chunk, "main", "Final answer"}, 500
      assert_receive {:llm_end, "main", _builder}, 500
    end

    test "returns error when pre-consumed text is empty" do
      # When pre_consumed_text is "" (empty string), process_text returns false
      # which triggers the error path in emit_response
      stub(BranchedLLM.ChatMock, :send_message_stream, fn _msg, _ctx, _opts ->
        {:ok, stream_response([]), &context_builder/1, [], ""}
      end)

      pid = self()

      params = %{
        message: "Hi",
        llm_context: make_context(),
        on_event: fn event -> send(pid, event) end,
        llm_tools: [],
        chat_mod: BranchedLLM.ChatMock,
        tool_usage_counts: %{},
        branch_id: "main"
      }

      {:ok, _pid} = ChatOrchestrator.run(params)

      # Empty text treated as error, triggers retries then error
      assert_receive {:llm_error, "main", _error}, 2000
    end
  end

  describe "run/1 handles exceptions" do
    test "formats exception and sends error" do
      stub(BranchedLLM.ChatMock, :send_message_stream, fn _msg, _ctx, _opts ->
        raise RuntimeError, "boom"
      end)

      pid = self()

      params = %{
        message: "Hi",
        llm_context: make_context(),
        on_event: fn event -> send(pid, event) end,
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
