defmodule BranchedLLM.OrchestratorTest do
  use ExUnit.Case, async: false
  import Mox

  alias BranchedLLM.ChatOrchestrator
  alias BranchedLLM.LLM.StreamResult.{ContentResult, EmptyResult, ToolCallResult}
  alias ReqLLM.Context
  alias ReqLLM.StreamResponse.MetadataHandle

  setup :set_mox_from_context

  defp make_context do
    Context.new([Context.system("System")])
  end

  defp stream_response(tokens, metadata \\ %{}) do
    stream = Stream.map(tokens, &%{text: &1, type: :content})

    {:ok, metadata_handle} =
      MetadataHandle.start_link(fn -> metadata end)

    %ReqLLM.StreamResponse{
      stream: stream,
      context: Context.new([]),
      model: "gpt-mock",
      cancel: fn -> :ok end,
      metadata_handle: metadata_handle
    }
  end

  describe "run/1 sends chunks and end through on_event" do
    test "basic streaming" do
      tokens = ["Hello", " world"]

      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _ctx, _opts ->
        {:ok, %ContentResult{stream: stream_response(tokens)}}
      end)

      pid = self()

      params = %{
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
      assert_receive {:llm_end, "main", "Hello world"}, 500
      assert_receive {:llm_metadata, "main", %{}}, 500
      assert_receive {:update_tool_usage_counts, _}, 500
    end
  end

  describe "run/1 emits llm_metadata" do
    test "with usage data from provider" do
      metadata = %{usage: %{input_tokens: 8, output_tokens: 12}}

      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _ctx, _opts ->
        {:ok, %ContentResult{stream: stream_response(["Hi"], metadata)}}
      end)

      pid = self()

      params = %{
        llm_context: make_context(),
        on_event: fn event -> send(pid, event) end,
        llm_tools: [],
        chat_mod: BranchedLLM.ChatMock,
        tool_usage_counts: %{},
        branch_id: "main"
      }

      {:ok, _pid} = ChatOrchestrator.run(params)

      assert_receive {:llm_metadata, "main", ^metadata}, 500
    end

    test "on tool call result" do
      metadata = %{usage: %{input_tokens: 5, output_tokens: 3}}
      tool_call = ReqLLM.ToolCall.new("call_1", "get_weather", ~s({"location": "NYC"}))

      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _ctx, _opts ->
        {:ok,
         %ToolCallResult{
           tool_calls: [tool_call],
           context: Context.new([]),
           metadata_handle: MetadataHandle.start_link(fn -> metadata end) |> elem(1)
         }}
      end)

      expect(BranchedLLM.ChatMock, :execute_tool, 1, fn _tool, _args ->
        {:ok, "Sunny"}
      end)

      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _ctx, _opts ->
        {:ok, %ContentResult{stream: stream_response(["Final answer"])}}
      end)

      pid = self()

      params = %{
        llm_context: make_context(),
        on_event: fn event -> send(pid, event) end,
        llm_tools: [%{name: "get_weather"}],
        chat_mod: BranchedLLM.ChatMock,
        tool_usage_counts: %{get_weather: 0},
        branch_id: "main"
      }

      {:ok, _pid} = ChatOrchestrator.run(params)

      assert_receive {:llm_metadata, "main", ^metadata}, 500
      assert_receive {:llm_end, "main", "Final answer"}, 500
    end

    test "with empty metadata" do
      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _ctx, _opts ->
        {:ok, %ContentResult{stream: stream_response(["ok"], %{})}}
      end)

      pid = self()

      params = %{
        llm_context: make_context(),
        on_event: fn event -> send(pid, event) end,
        llm_tools: [],
        chat_mod: BranchedLLM.ChatMock,
        tool_usage_counts: %{},
        branch_id: "main"
      }

      {:ok, _pid} = ChatOrchestrator.run(params)

      assert_receive {:llm_metadata, "main", %{}}, 500
    end

    test "not emitted when ToolCallResult has nil metadata_handle" do
      tool_call = ReqLLM.ToolCall.new("call_1", "get_weather", ~s({"location": "NYC"}))

      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _ctx, _opts ->
        {:ok,
         %ToolCallResult{
           tool_calls: [tool_call],
           context: Context.new([]),
           metadata_handle: nil
         }}
      end)

      expect(BranchedLLM.ChatMock, :execute_tool, 1, fn _tool, _args ->
        {:ok, "Sunny"}
      end)

      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _ctx, _opts ->
        {:ok, %ContentResult{stream: stream_response(["done"])}}
      end)

      pid = self()

      params = %{
        llm_context: make_context(),
        on_event: fn event -> send(pid, event) end,
        llm_tools: [%{name: "get_weather"}],
        chat_mod: BranchedLLM.ChatMock,
        tool_usage_counts: %{get_weather: 0},
        branch_id: "main"
      }

      {:ok, _pid} = ChatOrchestrator.run(params)

      # Only the final ContentResult should emit metadata (from its stream),
      # not the ToolCallResult (which has nil metadata_handle)
      assert_receive {:llm_end, "main", "done"}, 500
      # We should get exactly one :llm_metadata from the final ContentResult stream
      assert_receive {:llm_metadata, "main", %{}}, 500
    end
  end

  describe "run/1 handles errors" do
    test "returns error on failure" do
      stub(BranchedLLM.ChatMock, :send_message_stream, fn _ctx, _opts ->
        {:error, "Connection failed"}
      end)

      pid = self()

      params = %{
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

      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _ctx, opts ->
        :counters.add(call_count, 1, 1)
        assert Keyword.has_key?(opts, :tools)
        {:ok, %ContentResult{stream: stream_response(["response"])}}
      end)

      pid = self()

      params = %{
        llm_context: make_context(),
        on_event: fn event -> send(pid, event) end,
        llm_tools: [%{name: "test_tool"}],
        chat_mod: BranchedLLM.ChatMock,
        tool_usage_counts: %{test_tool: 0},
        branch_id: "main"
      }

      {:ok, _pid} = ChatOrchestrator.run(params)

      assert_receive {:llm_chunk, "main", "response"}, 500
      assert_receive {:llm_end, "main", "response"}, 500
    end
  end

  describe "run/1 handles tool calls and recurses" do
    test "executes tool and returns final answer" do
      tool_call = ReqLLM.ToolCall.new("call_1", "get_weather", ~s({"location": "NYC"}))

      # First call returns tool_calls
      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _ctx, _opts ->
        {:ok, %ToolCallResult{tool_calls: [tool_call], context: Context.new([])}}
      end)

      # Mock execute_tool for the tool call
      expect(BranchedLLM.ChatMock, :execute_tool, 1, fn _tool, _args ->
        {:ok, "Sunny"}
      end)

      # Second call (after recursion) returns text
      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _ctx, _opts ->
        {:ok, %ContentResult{stream: stream_response(["Final answer"])}}
      end)

      pid = self()

      params = %{
        llm_context: make_context(),
        on_event: fn event -> send(pid, event) end,
        llm_tools: [%{name: "get_weather"}],
        chat_mod: BranchedLLM.ChatMock,
        tool_usage_counts: %{get_weather: 0},
        branch_id: "main"
      }

      {:ok, _pid} = ChatOrchestrator.run(params)

      assert_receive {:llm_status, "main", _status}, 500
      assert_receive {:update_tool_usage_counts, %{get_weather: 1}}, 500
      assert_receive {:llm_chunk, "main", "Final answer"}, 500
      assert_receive {:llm_end, "main", "Final answer"}, 500
    end
  end

  describe "run/1 enforces tool usage limits" do
    test "skips tool execution when limit reached" do
      tool_call = ReqLLM.ToolCall.new("call_1", "limited_tool", ~s({}))

      # First call returns tool_calls
      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _ctx, _opts ->
        {:ok, %ToolCallResult{tool_calls: [tool_call], context: Context.new([])}}
      end)

      # No execute_tool call expected (limit reached), second call returns text
      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _ctx, _opts ->
        {:ok, %ContentResult{stream: stream_response(["done"])}}
      end)

      pid = self()

      params = %{
        llm_context: make_context(),
        on_event: fn event -> send(pid, event) end,
        llm_tools: [%{name: "limited_tool"}],
        chat_mod: BranchedLLM.ChatMock,
        tool_usage_counts: %{limited_tool: 10},
        branch_id: "main"
      }

      {:ok, _pid} = ChatOrchestrator.run(params)

      assert_receive {:update_tool_usage_counts, _}, 2000
      assert_receive {:llm_chunk, "main", "done"}, 500
      assert_receive {:llm_end, "main", "done"}, 500
    end
  end

  describe "run/1 handles empty stream" do
    test "retries when stream has no tokens (treated as error)" do
      # When process_stream returns false (no chunks), it's an error
      # which triggers retries. After 10 retries, it sends llm_error.
      stub(BranchedLLM.ChatMock, :send_message_stream, fn _ctx, _opts ->
        {:ok, %EmptyResult{}}
      end)

      pid = self()

      params = %{
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

      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _ctx, _opts ->
        {:ok, %ToolCallResult{tool_calls: [tool_call], context: Context.new([])}}
      end)

      # All tools at limit, no execute_tool call, second call returns text
      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _ctx, _opts ->
        {:ok, %ContentResult{stream: stream_response(["answer"])}}
      end)

      pid = self()

      params = %{
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
      assert_receive {:llm_end, "main", "answer"}, 500
    end
  end

  describe "run/1 handles exceptions" do
    test "formats exception and sends error" do
      stub(BranchedLLM.ChatMock, :send_message_stream, fn _ctx, _opts ->
        raise RuntimeError, "boom"
      end)

      pid = self()

      params = %{
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
