defmodule BranchedLLM do
  @moduledoc """
  A wrapper around [ReqLLM](https://hex.pm/packages/req_llm) that adds
  branching conversations, tool execution, and async orchestration.

  ## Core Concepts

    * `BranchedLLM.Message` — A lightweight, immutable message struct for conversations
    * `BranchedLLM.BranchedChat` — A tree-like conversation state with multiple branches
    * `BranchedLLM.Chat` — The ReqLLM-based chat implementation
    * `BranchedLLM.ChatOrchestrator` — Async orchestration of LLM requests with tool calls

  ## Getting Started

  1. Create a `BranchedLLM.BranchedChat` with initial messages and context
  2. Use `BranchedLLM.ChatOrchestrator` to run LLM requests asynchronously

  ## Configuration

      config :branched_llm,
        ai_model: System.get_env("LLM_MODEL") || "openai:cara-cpu",
        base_url: System.get_env("LLM_BASE_URL") || "http://localhost:11434",
        api_key: System.get_env("NVIDIA_API_KEY") || "ollama"

  """

  alias BranchedLLM.{BranchedChat, ChatOrchestrator, Message}
  alias ReqLLM.Context

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
  @spec send_message(BranchedChat.t(), String.t(), fun(), list(), map()) :: {:ok, pid()}
  def send_message(
        %BranchedChat{} = branched_chat,
        message,
        on_event,
        llm_tools,
        tool_usage_counts
      ) do
    llm_context =
      branched_chat
      |> BranchedChat.get_current_context()
      |> Context.append(Context.user(message))

    params = %{
      llm_context: llm_context,
      on_event: on_event,
      llm_tools: llm_tools,
      chat_mod: branched_chat.chat_module,
      tool_usage_counts: tool_usage_counts,
      branch_id: branched_chat.current_branch_id
    }

    ChatOrchestrator.run(params)
  end
end
