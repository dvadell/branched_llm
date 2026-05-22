defmodule BranchedLLM.ContextManager.Strategy.Percentage do
  @moduledoc """
  Percentage strategy: keep the last X% of conversation tokens.

  Instead of a hard message count, this strategy estimates tokens per message
  and retains the most recent messages that together account for the specified
  percentage of the total conversation tokens. System messages are always
  preserved and do not count toward the percentage.

  This is useful when messages vary widely in length (e.g., short questions
  but long tool results) and you want to retain a proportional amount of
  recent context.

  ## Usage

      config :branched_llm,
        max_tokens: 128_000,
        trim_callback: {BranchedLLM.ContextManager.Strategy.Percentage, :trim, [retain: 0.7]}

  ## Options

    * `:retain` — Fraction of conversation tokens to keep, as a float between 0.0 and 1.0 (default `0.7`, i.e., keep the most recent 70% of tokens).
  """

  @behaviour BranchedLLM.ContextManager.Strategy

  alias ReqLLM.Context
  alias ReqLLM.Message

  @chars_per_token 4
  @default_retain 0.7

  @impl true
  @spec trim(Context.t(), keyword()) :: Context.t()
  def trim(%Context{messages: messages} = context, opts) do
    retain = Keyword.get(opts, :retain, @default_retain)

    {system_messages, conversation_messages} =
      Enum.split_with(messages, fn
        %Message{role: :system} -> true
        _ -> false
      end)

    total_tokens =
      conversation_messages
      |> Enum.reduce(0, fn msg, acc -> acc + message_char_length(msg) end)
      |> Kernel.div(@chars_per_token)
      |> max(1)

    target_tokens = max(trunc(total_tokens * retain), 1)

    recent = take_recent_until_tokens(conversation_messages, target_tokens)

    %{context | messages: system_messages ++ recent}
  end

  ## Private Helpers

  @spec message_char_length(Message.t()) :: non_neg_integer()
  defp message_char_length(%Message{content: content_parts}) when is_list(content_parts) do
    Enum.reduce(content_parts, 0, fn
      %{type: :text, text: text}, acc when is_binary(text) -> acc + byte_size(text)
      _, acc -> acc
    end)
  end

  defp message_char_length(%Message{content: content}) when is_binary(content) do
    byte_size(content)
  end

  defp message_char_length(_), do: 0

  # Walk conversation messages from newest to oldest, accumulating tokens
  # until we reach the target, then reverse to restore chronological order.
  @spec take_recent_until_tokens([Message.t()], non_neg_integer()) :: [Message.t()]
  defp take_recent_until_tokens(conversation_messages, target_tokens) do
    conversation_messages
    |> Enum.reverse()
    |> accumulate_until_tokens(target_tokens, [])
    |> Enum.reverse()
  end

  @spec accumulate_until_tokens([Message.t()], non_neg_integer(), [Message.t()]) ::
          [Message.t()]
  defp accumulate_until_tokens([], _target, acc), do: acc

  defp accumulate_until_tokens([head | tail], target, acc) do
    head_tokens = max(message_char_length(head) |> Kernel.div(@chars_per_token), 1)
    current = Enum.reduce(acc, 0, fn msg, sum -> sum + message_token_count(msg) end)

    if current + head_tokens <= target do
      accumulate_until_tokens(tail, target, [head | acc])
    else
      acc
    end
  end

  defp message_token_count(msg) do
    max(message_char_length(msg) |> Kernel.div(@chars_per_token), 1)
  end
end
