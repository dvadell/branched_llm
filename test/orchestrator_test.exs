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
end
