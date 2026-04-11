defmodule BranchedLLM.OrchestratorTest do
  use ExUnit.Case, async: true
  import Mox
  alias BranchedLLM.Orchestrator
  alias BranchedLLM.Tree
  alias BranchedLLM.Message
  alias ReqLLM.Context

  setup :set_mox_from_context

  setup do
    chat_module = BranchedLLM.ChatMock
    initial_messages = [Message.new(:system, "System")]
    initial_context = Context.new([Context.system("System")])
    tree = Tree.new(chat_module, initial_messages, initial_context)
    {:ok, tree: tree}
  end

  test "run/4 sends chunks and done to caller_pid", %{tree: tree} do
    # Mock LLM streaming
    tokens = ["Hello", " world"]

    expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _msg, _ctx, _opts ->
      # Simulate a stream response. tokens/1 expects a stream of maps/structs with text and type.
      stream = Stream.map(tokens, &%{text: &1, type: :content})

      response = %ReqLLM.StreamResponse{
        stream: stream,
        context: Context.new([]),
        model: "gpt-mock",
        cancel: fn -> :ok end,
        metadata_task: Task.async(fn -> %{} end)
      }

      builder = fn content -> Context.new([Context.assistant(content)]) end

      {:ok, response, builder, []}
    end)

    Orchestrator.run(tree, "main", "Hi", caller_pid: self())

    assert_receive {:llm_chunk, "main", "Hello"}, 500
    assert_receive {:llm_chunk, "main", " world"}, 500
    assert_receive {:llm_done, "main", _builder}, 500
  end

  test "run/4 handles errors", %{tree: tree} do
    # Use stub if retry is involved to avoid unexpected call error
    stub(BranchedLLM.ChatMock, :send_message_stream, fn _msg, _ctx, _opts ->
      {:error, "Connection failed"}
    end)

    Orchestrator.run(tree, "main", "Hi", caller_pid: self())

    assert_receive {:llm_error, "main", "\"Connection failed\""}, 500
  end

  test "run/4 uses default caller_pid when not provided", %{tree: tree} do
    stub(BranchedLLM.ChatMock, :send_message_stream, fn _msg, _ctx, _opts ->
      stream = Stream.map(["test"], &%{text: &1, type: :content})

      response = %ReqLLM.StreamResponse{
        stream: stream,
        context: Context.new([]),
        model: "gpt-mock",
        cancel: fn -> :ok end,
        metadata_task: Task.async(fn -> %{} end)
      }

      builder = fn content -> Context.new([Context.assistant(content)]) end

      {:ok, response, builder, []}
    end)

    # Should not raise, just runs with self() as default
    Orchestrator.run(tree, "main", "Hi")
  end

  test "run/4 passes llm_tools and tool_usage_counts", %{tree: tree} do
    expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _msg, _ctx, opts ->
      # Verify tools are passed through
      assert Keyword.has_key?(opts, :tools)

      stream = Stream.map(["response"], &%{text: &1, type: :content})

      response = %ReqLLM.StreamResponse{
        stream: stream,
        context: Context.new([]),
        model: "gpt-mock",
        cancel: fn -> :ok end,
        metadata_task: Task.async(fn -> %{} end)
      }

      builder = fn content -> Context.new([Context.assistant(content)]) end

      {:ok, response, builder, []}
    end)

    mock_tool = %{name: "test_tool"}
    Orchestrator.run(tree, "main", "Hi", caller_pid: self(), llm_tools: [mock_tool], tool_usage_counts: %{"test_tool" => 0})

    assert_receive {:llm_chunk, "main", "response"}, 500
    assert_receive {:llm_done, "main", _builder}, 500
  end

  test "run/4 handles tool calls and recurses", %{tree: tree} do
    tool_call = ReqLLM.ToolCall.new("call_1", "get_weather", ~s({"location": "NYC"}))

    # First call returns tool_calls, second call (after recursion) returns done
    expect(BranchedLLM.ChatMock, :send_message_stream, fn _msg, _ctx, opts ->
      assert Keyword.has_key?(opts, :tools)

      # First time: return tool calls
      stream = Stream.map([], &%{text: &1, type: :content})

      response = %ReqLLM.StreamResponse{
        stream: stream,
        context: Context.new([]),
        model: "gpt-mock",
        cancel: fn -> :ok end,
        metadata_task: Task.async(fn -> %{} end)
      }

      builder = fn content -> Context.new([Context.assistant(content)]) end

      {:ok, response, builder, [tool_call]}
    end)

    # Mock execute_tool for the tool call
    expect(BranchedLLM.ChatMock, :execute_tool, fn _tool, _args -> {:ok, "Sunny"} end)

    # Stub for the recursive call (after tool execution)
    stub(BranchedLLM.ChatMock, :send_message_stream, fn _msg, _ctx, _opts ->
      stream = Stream.map(["Final answer"], &%{text: &1, type: :content})

      response = %ReqLLM.StreamResponse{
        stream: stream,
        context: Context.new([]),
        model: "gpt-mock",
        cancel: fn -> :ok end,
        metadata_task: Task.async(fn -> %{} end)
      }

      builder = fn content -> Context.new([Context.assistant(content)]) end

      {:ok, response, builder, []}
    end)

    mock_tool = %{name: "get_weather"}
    Orchestrator.run(tree, "main", "Weather?", caller_pid: self(), llm_tools: [mock_tool])

    assert_receive {:llm_tool_calls, "main", _, _}, 500
    assert_receive {:llm_status, "main", _}, 500
    assert_receive {:update_tool_usage_counts, _}, 500
    assert_receive {:llm_chunk, "main", "Final answer"}, 500
    assert_receive {:llm_done, "main", _builder}, 500
  end

  test "run/4 enforces tool usage limits", %{tree: tree} do
    tool_call = ReqLLM.ToolCall.new("call_1", "limited_tool", ~s({}))

    # First call returns tool_calls
    expect(BranchedLLM.ChatMock, :send_message_stream, fn _msg, _ctx, opts ->
      assert Keyword.has_key?(opts, :tools)
      stream = Stream.map([], &%{text: &1, type: :content})

      response = %ReqLLM.StreamResponse{
        stream: stream,
        context: Context.new([]),
        model: "gpt-mock",
        cancel: fn -> :ok end,
        metadata_task: Task.async(fn -> %{} end)
      }

      builder = fn content -> Context.new([Context.assistant(content)]) end

      {:ok, response, builder, [tool_call]}
    end)

    # Mock execute_tool
    expect(BranchedLLM.ChatMock, :execute_tool, fn _tool, _args -> {:ok, "result"} end)

    # After tool execution, the recursive call should return done
    stub(BranchedLLM.ChatMock, :send_message_stream, fn _msg, _ctx, _opts ->
      stream = Stream.map(["done"], &%{text: &1, type: :content})

      response = %ReqLLM.StreamResponse{
        stream: stream,
        context: Context.new([]),
        model: "gpt-mock",
        cancel: fn -> :ok end,
        metadata_task: Task.async(fn -> %{} end)
      }

      builder = fn content -> Context.new([Context.assistant(content)]) end

      {:ok, response, builder, []}
    end)

    # Pass tool_usage_counts with count already at 10 (limit)
    mock_tool = %{name: "limited_tool"}
    Orchestrator.run(tree, "main", "Use tool", caller_pid: self(), llm_tools: [mock_tool], tool_usage_counts: %{limited_tool: 10})

    assert_receive {:llm_tool_calls, "main", _, _}, 500
    assert_receive {:llm_status, "main", _}, 500
    assert_receive {:update_tool_usage_counts, _}, 500
    assert_receive {:llm_chunk, "main", "done"}, 500
    assert_receive {:llm_done, "main", _builder}, 500
  end
end
