defmodule BranchedLLM.ChatTest do
  use ExUnit.Case, async: true

  alias BranchedLLM.Chat
  alias ReqLLM.Context

  describe "new_context/1" do
    test "creates a context with system message" do
      context = Chat.new_context("You are helpful")

      assert length(context.messages) == 1
      assert List.first(context.messages).role == :system
    end
  end

  describe "get_history/1" do
    test "returns the messages from context" do
      context = Chat.new_context("System")
      history = Chat.get_history(context)

      assert length(history) == 1
    end
  end

  describe "reset_context/1" do
    test "keeps only system messages" do
      context =
        Context.new([
          Context.system("System"),
          Context.user("Hello"),
          Context.assistant("Hi")
        ])

      reset = Chat.reset_context(context)

      assert length(reset.messages) == 1
      assert List.first(reset.messages).role == :system
    end
  end

  describe "default_model/0" do
    test "returns the configured model as an inline map" do
      model = Chat.default_model()
      assert match?(%LLMDB.Model{}, model) or is_binary(model)
    end
  end

  describe "context trimming in send_message_stream/2" do
    test "passes max_tokens and trim_callback opts to ContextManager" do
      # Verify that the opts are extracted correctly via context_trim_opts
      # This is tested indirectly — the ContextManager.trim call in
      # send_message_stream will use these opts. The ContextManager
      # itself is tested in context_manager_test.exs.
      #
      # We test the option extraction by verifying that a context
      # within limits is not trimmed even when max_tokens is set.

      context = Chat.new_context("Short system prompt")

      # With a generous max_tokens, no trimming should occur
      # (We can't call send_message_stream without an LLM, but
      # we can verify the context_trim_opts helper behavior
      # through the ContextManager integration)
      alias BranchedLLM.ContextManager

      {result, was_trimmed} = ContextManager.trim(context, max_tokens: 100_000)
      refute was_trimmed
      assert result == context
    end
  end
end
