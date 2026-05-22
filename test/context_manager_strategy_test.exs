defmodule BranchedLLM.ContextManager.StrategyTest do
  use ExUnit.Case, async: true

  alias BranchedLLM.ContextManager.Strategy.Percentage
  alias BranchedLLM.ContextManager.Strategy.Prune
  alias BranchedLLM.ContextManager.Strategy.SlidingWindow
  alias BranchedLLM.ContextManager.Strategy.Summarize

  alias ReqLLM.Context
  alias ReqLLM.Message

  # Helper: build a context with a system message + N conversation pairs
  defp build_context(pair_count) do
    context = Context.new([Context.system("System prompt")])

    Enum.reduce(1..pair_count, context, fn i, acc ->
      acc
      |> Context.append(Context.user("Question number #{i}"))
      |> Context.append(Context.assistant("Answer number #{i}"))
    end)
  end

  # Helper: build a context with messages that have raw binary content
  defp context_with_binary_content do
    %Context{
      messages: [
        %Message{role: :system, content: [%Message.ContentPart{type: :text, text: "System"}]},
        %Message{role: :user, content: "Binary user message here"},
        %Message{role: :assistant, content: "Binary assistant reply"}
      ]
    }
  end

  # Helper: build a context with a message that has nil content
  defp context_with_nil_content do
    %Context{
      messages: [
        %Message{role: :system, content: [%Message.ContentPart{type: :text, text: "System"}]},
        struct(Message, %{role: :user, content: nil})
      ]
    }
  end

  # Helper: build a context with messages containing non-text ContentParts (e.g., image)
  defp context_with_mixed_content_parts do
    %Context{
      messages: [
        %Message{role: :system, content: [%Message.ContentPart{type: :text, text: "System"}]},
        %Message{
          role: :user,
          content: [
            %Message.ContentPart{type: :text, text: "What is in this image?"},
            %Message.ContentPart{
              type: :image_url,
              url: "https://example.com/img.png"
            }
          ]
        },
        %Message{role: :assistant, content: [%Message.ContentPart{type: :text, text: "An image"}]}
      ]
    }
  end

  # Helper: build a large context to exceed max_tokens
  defp build_large_context(pair_count) do
    context = Context.new([Context.system("System prompt")])

    Enum.reduce(1..pair_count, context, fn i, acc ->
      acc
      |> Context.append(Context.user("This is question number #{i} with some extra text"))
      |> Context.append(Context.assistant("This is answer number #{i} with some extra text"))
    end)
  end

  ## Strategy.Prune

  describe "Prune" do
    test "preserves system messages" do
      context = build_context(10)
      trimmed = Prune.trim(context, max_tokens: 5)

      system_msgs = Enum.filter(trimmed.messages, fn msg -> msg.role == :system end)
      assert length(system_msgs) == 1
    end

    test "drops oldest conversation messages to fit within max_tokens" do
      context = build_context(5)
      trimmed = Prune.trim(context, max_tokens: 10)

      assert length(trimmed.messages) < length(context.messages)
      last_msg = List.last(trimmed.messages)
      assert last_msg.role == :assistant
    end

    test "returns context as-is when within limit" do
      context = Context.new([Context.system("Hi")])
      trimmed = Prune.trim(context, max_tokens: 100_000)
      assert length(trimmed.messages) == length(context.messages)
    end

    test "handles messages with binary (non-list) content" do
      context = context_with_binary_content()
      trimmed = Prune.trim(context, max_tokens: 3)

      # Should still trim correctly with binary content
      system_msgs = Enum.filter(trimmed.messages, fn msg -> msg.role == :system end)
      assert length(system_msgs) == 1
    end

    test "handles messages with nil content" do
      context = context_with_nil_content()
      trimmed = Prune.trim(context, max_tokens: 1)

      system_msgs = Enum.filter(trimmed.messages, fn msg -> msg.role == :system end)
      assert length(system_msgs) == 1
    end

    test "handles messages with non-text ContentParts (e.g., image)" do
      context = context_with_mixed_content_parts()
      trimmed = Prune.trim(context, max_tokens: 2)

      # Image content parts are skipped in token estimation
      system_msgs = Enum.filter(trimmed.messages, fn msg -> msg.role == :system end)
      assert length(system_msgs) == 1
    end
  end

  ## Strategy.SlidingWindow

  describe "SlidingWindow" do
    test "keeps only the last N conversation messages" do
      context = build_context(10)
      trimmed = SlidingWindow.trim(context, keep: 4)
      assert length(trimmed.messages) == 5
    end

    test "preserves system messages" do
      context = build_context(10)
      trimmed = SlidingWindow.trim(context, keep: 2)

      system_msgs = Enum.filter(trimmed.messages, fn msg -> msg.role == :system end)
      assert length(system_msgs) == 1
    end

    test "keeps the most recent messages" do
      context = build_context(5)
      trimmed = SlidingWindow.trim(context, keep: 2)

      conversation = Enum.filter(trimmed.messages, fn msg -> msg.role != :system end)
      assert length(conversation) == 2
      last = List.last(conversation)
      assert last.role == :assistant
    end

    test "does not trim when conversation is shorter than keep" do
      context = build_context(2)
      trimmed = SlidingWindow.trim(context, keep: 10)
      assert length(trimmed.messages) == length(context.messages)
    end

    test "uses default keep value of 10" do
      context = build_context(8)
      trimmed = SlidingWindow.trim(context, [])
      assert length(trimmed.messages) == 11
    end
  end

  ## Strategy.Percentage

  describe "Percentage" do
    test "keeps roughly the specified percentage of conversation tokens" do
      context = build_context(10)
      trimmed = Percentage.trim(context, retain: 0.5)

      assert length(trimmed.messages) < length(context.messages)
      assert length(trimmed.messages) > 1
    end

    test "preserves system messages" do
      context = build_context(5)
      trimmed = Percentage.trim(context, retain: 0.3)

      system_msgs = Enum.filter(trimmed.messages, fn msg -> msg.role == :system end)
      assert length(system_msgs) == 1
    end

    test "keeps the most recent messages" do
      context = build_context(5)
      trimmed = Percentage.trim(context, retain: 0.3)

      last_msg = List.last(trimmed.messages)
      assert last_msg.role == :assistant
    end

    test "retain: 1.0 keeps all messages" do
      context = build_context(3)
      trimmed = Percentage.trim(context, retain: 1.0)
      assert length(trimmed.messages) == length(context.messages)
    end

    test "uses default retain value of 0.7" do
      context = build_context(10)
      trimmed = Percentage.trim(context, [])
      assert length(trimmed.messages) < length(context.messages)
    end

    test "handles messages with binary (non-list) content" do
      context = context_with_binary_content()
      trimmed = Percentage.trim(context, retain: 0.5)

      system_msgs = Enum.filter(trimmed.messages, fn msg -> msg.role == :system end)
      assert length(system_msgs) == 1
    end

    test "handles messages with nil content" do
      context = context_with_nil_content()
      trimmed = Percentage.trim(context, retain: 0.5)

      system_msgs = Enum.filter(trimmed.messages, fn msg -> msg.role == :system end)
      assert length(system_msgs) == 1
    end

    test "handles messages with non-text ContentParts (e.g., image)" do
      context = context_with_mixed_content_parts()
      trimmed = Percentage.trim(context, retain: 0.5)

      system_msgs = Enum.filter(trimmed.messages, fn msg -> msg.role == :system end)
      assert length(system_msgs) == 1
    end
  end

  ## Strategy.Summarize

  describe "Summarize" do
    test "creates a summary message from old messages" do
      context = build_context(5)
      trimmed = Summarize.trim(context, recent_count: 2)
      assert length(trimmed.messages) == 4
    end

    test "preserves system messages" do
      context = build_context(5)
      trimmed = Summarize.trim(context, recent_count: 2)

      system_msgs = Enum.filter(trimmed.messages, fn msg -> msg.role == :system end)
      assert length(system_msgs) == 1
    end

    test "summary message has [Conversation summary] prefix" do
      context = build_context(5)
      trimmed = Summarize.trim(context, recent_count: 2)

      non_system = Enum.filter(trimmed.messages, fn msg -> msg.role != :system end)
      summary_msg = List.first(non_system)
      text = extract_text(summary_msg)
      assert String.starts_with?(text, "[Conversation summary]")
    end

    test "keeps recent messages intact" do
      context = build_context(5)
      trimmed = Summarize.trim(context, recent_count: 4)

      conversation = Enum.filter(trimmed.messages, fn msg -> msg.role != :system end)
      recent = Enum.take(conversation, -4)

      Enum.each(recent, fn msg ->
        text = extract_text(msg)
        refute String.starts_with?(text, "[Conversation summary]")
      end)
    end

    test "does not summarize when conversation is short enough" do
      context = build_context(2)
      trimmed = Summarize.trim(context, recent_count: 10)
      assert length(trimmed.messages) == length(context.messages)
    end

    test "uses custom summarizer function" do
      context = build_context(5)
      custom_summarizer = fn _text -> "Custom summary!" end
      trimmed = Summarize.trim(context, recent_count: 2, summarizer: custom_summarizer)

      non_system = Enum.filter(trimmed.messages, fn msg -> msg.role != :system end)
      summary_msg = List.first(non_system)
      text = extract_text(summary_msg)
      assert text =~ "Custom summary!"
    end

    test "uses default recent_count of 4" do
      context = build_context(5)
      trimmed = Summarize.trim(context, [])
      assert length(trimmed.messages) == 6
    end

    test "default_summarizer truncates text over 500 characters" do
      long_text = String.duplicate("abcdefghij", 60)
      result = Summarize.default_summarizer(long_text)
      assert String.ends_with?(result, "...")
      assert String.length(result) <= 510
    end

    test "default_summarizer returns short text as-is" do
      short_text = "Hello world"
      result = Summarize.default_summarizer(short_text)
      assert result == short_text
    end

    test "handles messages with binary (non-list) content" do
      context = context_with_binary_content()

      # Only 2 conversation messages, recent_count: 1 triggers summarization
      trimmed = Summarize.trim(context, recent_count: 1)

      # Should have: 1 system + 1 summary + 1 recent = 3
      assert length(trimmed.messages) == 3

      non_system = Enum.filter(trimmed.messages, fn msg -> msg.role != :system end)
      summary_msg = List.first(non_system)
      text = extract_text(summary_msg)
      assert String.starts_with?(text, "[Conversation summary]")
    end

    test "handles messages with nil content" do
      # Create a context with multiple messages including one with nil content
      context = %Context{
        messages: [
          %Message{role: :system, content: [%Message.ContentPart{type: :text, text: "System"}]},
          struct(Message, %{role: :user, content: nil}),
          %Message{role: :assistant, content: [%Message.ContentPart{type: :text, text: "Hi"}]},
          %Message{role: :user, content: [%Message.ContentPart{type: :text, text: "Recent"}]},
          %Message{role: :assistant, content: [%Message.ContentPart{type: :text, text: "Bye"}]}
        ]
      }

      # recent_count: 2 means last 2 messages are kept, the nil-content message is in old_msgs
      trimmed = Summarize.trim(context, recent_count: 2)

      # 1 system + 1 summary + 2 recent = 4
      assert length(trimmed.messages) == 4
    end

    test "handles messages with non-text ContentParts (e.g., image)" do
      context = context_with_mixed_content_parts()
      # 1 system + 1 user (with image) + 1 assistant = 3 messages
      # recent_count: 1 means 1 recent kept, so user+image is summarized
      trimmed = Summarize.trim(context, recent_count: 1)

      # 1 system + 1 summary + 1 recent = 3
      assert length(trimmed.messages) == 3
      non_system = Enum.filter(trimmed.messages, fn msg -> msg.role != :system end)
      summary_msg = List.first(non_system)
      text = extract_text(summary_msg)
      assert String.starts_with?(text, "[Conversation summary]")
    end
  end

  ## Integration: ContextManager.trim with strategies via 3-tuple

  describe "ContextManager.trim with strategy tuples" do
    alias BranchedLLM.ContextManager

    test "invokes SlidingWindow strategy when context exceeds max_tokens" do
      # 50 pairs produce 100+ conversation messages, well over max_tokens: 5
      context = build_large_context(50)

      {trimmed, was_trimmed} =
        ContextManager.trim(context,
          max_tokens: 5,
          trim_callback: {SlidingWindow, :trim, [keep: 2]}
        )

      assert was_trimmed

      system_msgs = Enum.filter(trimmed.messages, fn msg -> msg.role == :system end)
      assert length(system_msgs) == 1
    end

    test "invokes Percentage strategy when context exceeds max_tokens" do
      context = build_large_context(50)

      {trimmed, was_trimmed} =
        ContextManager.trim(context,
          max_tokens: 5,
          trim_callback: {Percentage, :trim, [retain: 0.3]}
        )

      assert was_trimmed
      assert length(trimmed.messages) < length(context.messages)
    end

    test "invokes 2-tuple callback with empty opts when context exceeds max_tokens" do
      context = build_large_context(50)

      {trimmed, was_trimmed} =
        ContextManager.trim(context,
          max_tokens: 5,
          trim_callback: {SlidingWindow, :trim}
        )

      assert was_trimmed

      system_msgs = Enum.filter(trimmed.messages, fn msg -> msg.role == :system end)
      assert length(system_msgs) == 1
    end

    test "falls back to Prune when strategy result still exceeds max_tokens" do
      noop = fn ctx -> ctx end

      context = build_context(5)

      {trimmed, was_trimmed} =
        ContextManager.trim(context,
          max_tokens: 3,
          trim_callback: noop
        )

      assert was_trimmed

      system_msgs = Enum.filter(trimmed.messages, fn msg -> msg.role == :system end)
      assert length(system_msgs) == 1
      assert length(trimmed.messages) < length(context.messages)
    end
  end

  ## Helpers

  defp extract_text(%ReqLLM.Message{content: content_parts}) when is_list(content_parts) do
    content_parts
    |> Enum.filter(fn
      %{type: :text} -> true
      _ -> false
    end)
    |> Enum.map_join(fn %{text: text} -> text end)
  end

  defp extract_text(%ReqLLM.Message{content: content}) when is_binary(content) do
    content
  end

  defp extract_text(_), do: ""
end
