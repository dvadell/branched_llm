defmodule BranchedLLMTest do
  use ExUnit.Case, async: false
  import Mox
  alias BranchedLLM.BranchedChat
  alias ReqLLM.Context

  setup :set_mox_from_context

  describe "new_chat/3" do
    test "creates a BranchedChat using the convenience function" do
      ctx = Context.new([Context.system("test")])

      chat = BranchedLLM.new_chat(BranchedLLM.ChatMock, [], ctx)

      assert %BranchedChat{} = chat
      assert chat.current_branch_id == "main"
    end
  end

  describe "send_message/5" do
    test "sends a message through the orchestrator" do
      ctx = Context.new([Context.system("test")])
      chat = BranchedLLM.new_chat(BranchedLLM.ChatMock, [], ctx)

      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _msg, _ctx, _opts ->
        stream = Stream.map(["Hi"], &%{text: &1, type: :content})

        {:ok,
         %ReqLLM.StreamResponse{
           stream: stream,
           context: ctx,
           model: "mock",
           cancel: fn -> :ok end,
           metadata_task: Task.async(fn -> %{} end)
         }, fn t -> Context.new([Context.assistant(t)]) end, []}
      end)

      test_pid = self()

      {:ok, _pid} =
        BranchedLLM.send_message(chat, "Hello", fn event -> send(test_pid, event) end, [], %{})

      assert_receive {:llm_chunk, "main", "Hi"}, 500
      assert_receive {:llm_end, "main", _builder}, 500
      assert_receive {:update_tool_usage_counts, _}, 500
    end
  end
end
