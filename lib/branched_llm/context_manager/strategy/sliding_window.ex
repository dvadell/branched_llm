defmodule BranchedLLM.ContextManager.Strategy.SlidingWindow do
  @moduledoc """
  Sliding window strategy: keep only the last N conversation messages.

  This strategy ignores token counting and simply retains the most recent N
  non-system messages, dropping everything else. It's the simplest approach
  and works well when you know roughly how many messages fit in your context
  window.

  System messages are always preserved and do not count toward the window size.

  ## Usage

      config :branched_llm,
        max_tokens: 128_000,
        trim_callback: {BranchedLLM.ContextManager.Strategy.SlidingWindow, :trim, [keep: 20]}

  ## Options

    * `:keep` — Number of most recent conversation messages to retain (default `10`).
  """

  @behaviour BranchedLLM.ContextManager.Strategy

  alias ReqLLM.Context
  alias ReqLLM.Message

  @default_keep 10

  @impl true
  @spec trim(Context.t(), keyword()) :: Context.t()
  def trim(%Context{messages: messages} = context, opts) do
    keep = Keyword.get(opts, :keep, @default_keep)

    {system_messages, conversation_messages} =
      Enum.split_with(messages, fn
        %Message{role: :system} -> true
        _ -> false
      end)

    recent = Enum.take(conversation_messages, -keep)

    %{context | messages: system_messages ++ recent}
  end
end
