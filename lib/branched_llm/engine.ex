defmodule BranchedLLM.Engine do
  @moduledoc """
  A pure functional state machine for orchestrating LLM Reason-Act-Answer loops.
  """

  alias BranchedLLM.Message

  @type tree :: BranchedLLM.Tree.t()
  @type response ::
          {:chunk, String.t()}
          | {:error, String.t()}
          | {:tool_calls, list(), function()}
          | {:done, function()}
  @type result ::
          {:continue, tree()}
          | {:halt, tree(), String.t()}
          | {:execute_tools, tree(), list()}
          | {:ok, tree()}

  @doc """
  Processes a raw LLM response (streaming chunk, error, or tool calls)
  and returns the next action and updated tree.
  """
  @spec process_response(tree(), String.t(), response()) :: result()
  def process_response(tree, branch_id, {:chunk, chunk}) do
    updated_tree = append_chunk(tree, branch_id, chunk)
    {:continue, updated_tree}
  end

  def process_response(tree, branch_id, {:error, reason}) do
    updated_tree = add_error_message(tree, branch_id, reason)
    {:halt, updated_tree, reason}
  end

  def process_response(tree, branch_id, {:tool_calls, tool_calls, context_builder}) do
    # When tool calls are found, we need the caller to execute them.
    # We update the tree to reflect that tools are being called.
    updated_tree =
      finish_assistant_message(tree, branch_id, context_builder, tool_calls: tool_calls)

    {:execute_tools, updated_tree, tool_calls}
  end

  def process_response(tree, branch_id, {:done, context_builder}) do
    updated_tree = finish_assistant_message(tree, branch_id, context_builder)
    {:ok, updated_tree}
  end

  # Internal helpers (moved and adapted from BranchedChat)

  defp append_chunk(tree, branch_id, chunk) do
    branch = tree.branches[branch_id]
    updated_messages = do_append_chunk(chunk, branch.messages)
    updated_branch = %{branch | messages: updated_messages}
    %{tree | branches: Map.put(tree.branches, branch_id, updated_branch)}
  end

  defp do_append_chunk("", messages), do: messages

  defp do_append_chunk(chunk, messages) do
    case List.last(messages) do
      %{sender: :assistant, deleted: false} = last ->
        List.replace_at(messages, -1, %{last | content: last.content <> chunk})

      _ ->
        messages ++ [Message.new(:assistant, chunk)]
    end
  end

  defp finish_assistant_message(tree, branch_id, context_builder, opts \\ []) do
    branch = tree.branches[branch_id]
    last_msg = List.last(branch.messages)
    content = if last_msg.sender == :assistant, do: last_msg.content, else: ""

    # Update context using the builder provided by the LLM client
    updated_context = context_builder.(content)

    # If there are tool calls, they are already in the context from the builder
    # but we might want to store them in the message metadata for UI
    tool_calls = Keyword.get(opts, :tool_calls, [])

    updated_messages =
      case {last_msg, tool_calls} do
        {%{sender: :assistant}, []} ->
          branch.messages

        {%{sender: :assistant}, calls} ->
          List.replace_at(branch.messages, -1, %{
            last_msg
            | metadata: Map.put(last_msg.metadata, :tool_calls, calls)
          })

        {_, []} ->
          branch.messages ++ [Message.new(:assistant, content)]

        {_, calls} ->
          branch.messages ++ [Message.new(:assistant, content, metadata: %{tool_calls: calls})]
      end

    updated_branch = %{branch | messages: updated_messages, context: updated_context}
    %{tree | branches: Map.put(tree.branches, branch_id, updated_branch)}
  end

  defp add_error_message(tree, branch_id, error_content) do
    error_message_obj = Message.new(:assistant, "Error: #{error_content}")
    branch = tree.branches[branch_id]
    updated_branch = %{branch | messages: branch.messages ++ [error_message_obj]}
    %{tree | branches: Map.put(tree.branches, branch_id, updated_branch)}
  end
end
