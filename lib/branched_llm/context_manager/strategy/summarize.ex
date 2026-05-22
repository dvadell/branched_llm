defmodule BranchedLLM.ContextManager.Strategy.Summarize do
  @moduledoc """
  Summarization strategy: condense older messages into a single summary.

  Instead of dropping messages, this strategy splits the conversation into
  "old" and "recent" segments, summarizes the old segment into a single user
  message, and prepends it before the recent messages.

  This preserves more context than pruning while staying within token limits.

  **Note:** This is a stub. The actual LLM-based summarization call is not yet
  implemented and currently falls back to a simple text concatenation.
  Replace `summarize_messages/1` with a real LLM call for production use.

  ## Usage

      config :branched_llm,
        max_tokens: 128_000,
        trim_callback: {BranchedLLM.ContextManager.Strategy.Summarize, :trim, [recent_count: 4]}

  ## Options

    * `:recent_count` — Number of most recent conversation messages to keep
      intact (default `4`). Everything before this is summarized.
    * `:summarizer` — A function `(String.t() -> String.t())` that produces
      a summary from raw message text. Defaults to
      `&__MODULE__.default_summarizer/1`, which simply concatenates messages.
      Replace with an LLM call for real summarization.

  ## Implementing a Real Summarizer

  The `:summarizer` option receives the concatenated text of old messages and
  must return a summary string. Plug in an LLM call like so:

      defmodule MyApp.Summarizer do
        def call(text) do
          {:ok, summary, _context} = BranchedLLM.Chat.send_message(
            "Summarize this conversation concisely:\\n\#{text}",
            summary_context()
          )
          summary
        end

        defp summary_context do
          BranchedLLM.Chat.new_context("You are a conversation summarizer.")
        end
      end

      config :branched_llm,
        max_tokens: 128_000,
        trim_callback: {BranchedLLM.ContextManager.Strategy.Summarize, :trim,
          [recent_count: 6, summarizer: &MyApp.Summarizer.call/1]}

  """

  @behaviour BranchedLLM.ContextManager.Strategy

  alias ReqLLM.Context
  alias ReqLLM.Message

  @default_recent_count 4

  @impl true
  @spec trim(Context.t(), keyword()) :: Context.t()
  def trim(%Context{messages: messages} = context, opts) do
    recent_count = Keyword.get(opts, :recent_count, @default_recent_count)
    summarizer = Keyword.get(opts, :summarizer, &default_summarizer/1)

    {system_messages, conversation_messages} =
      Enum.split_with(messages, fn
        %Message{role: :system} -> true
        _ -> false
      end)

    {old_msgs, recent_msgs} = Enum.split(conversation_messages, -recent_count)

    case old_msgs do
      [] ->
        # Nothing to summarize — conversation is short enough
        context

      _ ->
        raw_text = concatenate_messages(old_msgs)
        summary_text = summarizer.(raw_text)

        summary_msg = %Message{
          role: :user,
          content: [
            %Message.ContentPart{type: :text, text: "[Conversation summary] #{summary_text}"}
          ],
          name: nil,
          tool_call_id: nil,
          tool_calls: nil,
          metadata: %{}
        }

        %{context | messages: system_messages ++ [summary_msg] ++ recent_msgs}
    end
  end

  @doc """
  Default summarizer: simple text concatenation.

  This is a placeholder. Replace with an LLM call for real summarization.
  """
  @spec default_summarizer(String.t()) :: String.t()
  def default_summarizer(text) do
    # For production, replace this stub with an LLM summarization call
    # (see @moduledoc "Implementing a Real Summarizer" for an example).

    # Fallback: truncate to a reasonable length
    if String.length(text) > 500 do
      String.slice(text, 0, 500) <> "..."
    else
      text
    end
  end

  ## Private Helpers

  defp concatenate_messages(messages) do
    Enum.map_join(messages, "\n", fn msg ->
      text = extract_text(msg)
      "#{msg.role}: #{text}"
    end)
  end

  defp extract_text(%Message{content: content_parts}) when is_list(content_parts) do
    content_parts
    |> Enum.filter(fn
      %{type: :text} -> true
      _ -> false
    end)
    |> Enum.map_join(fn %{text: text} -> text end)
  end

  defp extract_text(%Message{content: content}) when is_binary(content) do
    content
  end

  defp extract_text(_), do: ""
end
