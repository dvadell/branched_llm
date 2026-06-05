defmodule BranchedLLM.ContextManager.Strategy.Prune do
  @moduledoc """
  Pruning strategy: drop the oldest non-system messages until the context fits.

  This is the simplest and most predictable strategy. System messages are always
  preserved. The most recent conversation messages are kept; older ones are
  removed from the front until the estimated token count is within `max_tokens`.

  This strategy is used as the default fallback in `ContextManager.trim/2`
  when no `trim_callback` is provided, or when a callback's result still
  exceeds the limit.

  ## Usage

      config :branched_llm,
        max_tokens: 128_000,
        trim_callback: {BranchedLLM.ContextManager.Strategy.Prune, :trim}

  ## Options

  This strategy does not accept any options beyond what `ContextManager.trim/2`
  provides (`max_tokens`). It is driven entirely by the token limit.
  """

  @behaviour BranchedLLM.ContextManager.Strategy

  alias BranchedLLM.ContextManager
  alias ReqLLM.Context
  alias ReqLLM.Message

  @chars_per_token 4

  @impl true
  @spec trim(Context.t(), keyword()) :: Context.t()
  def trim(%Context{messages: messages} = context, opts) do
    max_tokens = ContextManager.resolve_max_tokens(opts)

    {system_messages, conversation_messages} =
      Enum.split_with(messages, fn
        %Message{role: :system} -> true
        _ -> false
      end)

    system_token_estimate =
      system_messages
      |> Enum.reduce(0, fn msg, acc -> acc + message_char_length(msg) end)
      |> Kernel.div(@chars_per_token)

    available_tokens = max_tokens - system_token_estimate

    pruned_conversation = drop_until_fits(conversation_messages, available_tokens, [])

    %{context | messages: system_messages ++ pruned_conversation}
  end

  ## Private Helpers

  @spec message_char_length(Message.t()) :: non_neg_integer()
  defp message_char_length(%Message{content: content_parts}) when is_list(content_parts) do
    Enum.reduce(content_parts, 0, fn
      %{type: :text, text: text}, acc when is_binary(text) -> acc + byte_size(text)
    end)
  end

  @spec drop_until_fits([Message.t()], non_neg_integer(), [Message.t()]) :: [Message.t()]
  defp drop_until_fits([], _available_tokens, acc), do: Enum.reverse(acc)

  defp drop_until_fits([head | tail], available_tokens, acc) do
    head_tokens = max(message_char_length(head) |> Kernel.div(@chars_per_token), 1)

    current_total =
      acc
      |> Enum.reduce(0, fn msg, sum ->
        sum + max(message_char_length(msg) |> Kernel.div(@chars_per_token), 1)
      end)

    if current_total + head_tokens <= available_tokens do
      drop_until_fits(tail, available_tokens, [head | acc])
    else
      drop_until_fits(tail, available_tokens, acc)
    end
  end
end
