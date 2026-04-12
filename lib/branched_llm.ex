defmodule BranchedLLM do
  @moduledoc """
  BranchedLLM is a library for building LLM-powered applications with support
  for branching conversations, tool execution, and streaming responses.

  ## Core Concepts

    * `BranchedLLM.Message` — A lightweight, immutable message struct for conversations
    * `BranchedLLM.BranchedChat` — A tree-like conversation state with multiple branches
    * `BranchedLLM.ChatBehaviour` — Behaviour contract for LLM chat implementations
    * `BranchedLLM.Chat` — A default `ReqLLM`-based chat implementation
    * `BranchedLLM.ChatOrchestrator` — Async orchestration of LLM requests with tool calls

  ## Getting Started

  1. Implement `BranchedLLM.ChatBehaviour` or use the default `BranchedLLM.Chat`
  2. Create a `BranchedLLM.BranchedChat` with your initial messages and context
  3. Use `BranchedLLM.ChatOrchestrator` to run LLM requests asynchronously

  ## Configuration

      config :branched_llm,
        ai_model: "openai:gpt-4",
        base_url: "http://localhost:11434"

  """

  alias BranchedLLM.{BranchedChat, ChatOrchestrator, Message}

  @doc """
  Creates a new `BranchedChat` with the given chat module, initial messages, and context.

      iex> BranchedLLM.new_chat(BranchedLLM.Chat, [], context)
      %BranchedLLM.BranchedChat{...}

  """
  @spec new_chat(module(), [Message.t()], ReqLLM.Context.t()) :: BranchedChat.t()
  def new_chat(chat_module, initial_messages, initial_context) do
    BranchedChat.new(chat_module, initial_messages, initial_context)
  end

  @doc """
  Sends a single message through the orchestrator.

  This is a convenience wrapper around `ChatOrchestrator.run/1`.
  """
  @spec send_message(BranchedChat.t(), String.t(), pid(), list(), map()) :: {:ok, pid()}
  def send_message(
        %BranchedChat{} = branched_chat,
        message,
        caller_pid,
        llm_tools,
        tool_usage_counts
      ) do
    params = %{
      message: message,
      llm_context: BranchedChat.get_current_context(branched_chat),
      caller_pid: caller_pid,
      llm_tools: llm_tools,
      chat_mod: branched_chat.chat_module,
      tool_usage_counts: tool_usage_counts,
      branch_id: branched_chat.current_branch_id
    }

    ChatOrchestrator.run(params)
  end
end
