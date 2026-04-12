defmodule BranchedLLM.BranchedChat do
  @moduledoc """
  Manages a tree-like conversation structure with multiple branches.

  Messages are stored as `BranchedLLM.Message` structs internally. The `branch_metadata`
  type documents the shape of each branch's data.

  ## Message Protocol

  Each message in a branch's `messages` list is a `BranchedLLM.Message` struct with:
    * `:role` - `:user`, `:assistant`, or `:system`
    * `:content` - The text content
    * `:id` - Unique identifier
    * `:metadata` - Optional map (e.g., `%{deleted: true}`)

  ## Example

      iex> chat = BranchedLLM.BranchedChat.new(MyChatModule, [], initial_context)
      iex> chat = BranchedLLM.BranchedChat.add_user_message(chat, "Hello!")
      iex> BranchedLLM.BranchedChat.get_current_messages(chat)
      [%BranchedLLM.Message{role: :user, content: "Hello!", ...}]

  """

  alias BranchedLLM.Message

  defstruct [
    :branches,
    :branch_ids,
    :current_branch_id,
    :child_branches,
    :chat_module
  ]

  @type branch_metadata :: %{
          name: String.t(),
          messages: [Message.t()],
          context: ReqLLM.Context.t(),
          parent_branch_id: String.t() | nil,
          parent_message_id: String.t() | nil,
          active_task: pid() | nil,
          pending_messages: [String.t()],
          tool_status: String.t() | nil,
          current_user_message: String.t() | nil
        }

  @type t :: %__MODULE__{
          branches: %{String.t() => branch_metadata()},
          branch_ids: [String.t()],
          current_branch_id: String.t(),
          child_branches: %{String.t() => [String.t()]},
          chat_module: module()
        }

  @doc """
  Initializes a new branched chat.
  """
  def new(chat_module, initial_messages, initial_context) do
    initial_branch_id = "main"

    %__MODULE__{
      chat_module: chat_module,
      current_branch_id: initial_branch_id,
      branch_ids: [initial_branch_id],
      child_branches: %{},
      branches: %{
        initial_branch_id => %{
          name: "Main Conversation",
          messages: initial_messages,
          context: initial_context,
          parent_branch_id: nil,
          parent_message_id: nil,
          active_task: nil,
          pending_messages: [],
          tool_status: nil,
          current_user_message: nil
        }
      }
    }
  end

  @doc """
  Changes the active branch.
  """
  def switch_branch(%__MODULE__{} = t, branch_id) do
    if Map.has_key?(t.branches, branch_id) do
      %{t | current_branch_id: branch_id}
    else
      t
    end
  end

  @doc """
  Adds a user message to the current branch.
  """
  def add_user_message(%__MODULE__{} = t, content) do
    user_message = Message.new(:user, content)

    branch = t.branches[t.current_branch_id]

    # Update name if it's empty (meaning this is the first message in a new branch)
    name =
      if branch.name == "" do
        snippet =
          content
          |> String.slice(0, 30)
          |> String.trim()

        if String.length(content) > 30, do: snippet <> "...", else: snippet
      else
        branch.name
      end

    updated_branch = %{branch | name: name, messages: branch.messages ++ [user_message]}
    branches = Map.put(t.branches, t.current_branch_id, updated_branch)

    %{t | branches: branches}
  end

  @doc """
  Appends an AI chunk to a specific branch.
  """
  def append_chunk(%__MODULE__{} = t, branch_id, chunk) do
    branch = t.branches[branch_id]
    updated_messages = do_append_chunk(chunk, branch.messages)
    updated_branch = %{branch | messages: updated_messages, tool_status: nil}
    branches = Map.put(t.branches, branch_id, updated_branch)

    %{t | branches: branches}
  end

  defp do_append_chunk("", messages), do: messages

  defp do_append_chunk(chunk, messages) do
    case List.last(messages) do
      %Message{role: :assistant} = last ->
        {_last, rest} = List.pop_at(messages, -1)
        rest ++ [%{last | content: last.content <> chunk}]

      _ ->
        messages ++ [Message.new(:assistant, chunk)]
    end
  end

  @doc """
  Finalizes an AI response with the new context.
  """
  def finish_ai_response(%__MODULE__{} = t, branch_id, llm_context_builder) do
    branch = t.branches[branch_id]
    final_content = get_last_assistant_message_content(branch.messages)
    updated_llm_context = llm_context_builder.(final_content)

    updated_branch = %{
      branch
      | context: updated_llm_context,
        active_task: nil,
        current_user_message: nil,
        tool_status: nil
    }

    branches = Map.put(t.branches, branch_id, updated_branch)

    %{t | branches: branches}
  end

  defp get_last_assistant_message_content(messages) do
    case List.last(messages) do
      %Message{role: :assistant, content: content} -> content
      _ -> ""
    end
  end

  @doc """
  Appends an error message to a branch.
  """
  def add_error_message(%__MODULE__{} = t, branch_id, error_content) do
    error_message_obj = Message.new(:assistant, error_content)

    branch = t.branches[branch_id]

    updated_branch = %{
      branch
      | messages: branch.messages ++ [error_message_obj],
        active_task: nil,
        current_user_message: nil,
        tool_status: nil
    }

    branches = Map.put(t.branches, branch_id, updated_branch)

    %{t | branches: branches}
  end

  @doc """
  Creates a new branch from a message in the current branch.
  """
  def branch_off(%__MODULE__{} = t, message_id) do
    messages = t.branches[t.current_branch_id].messages
    idx = Enum.find_index(messages, fn msg -> msg.id == message_id end)

    if is_nil(idx) do
      t
    else
      new_messages = Enum.slice(messages, 0..idx)
      new_llm_context = rebuild_context_from_messages(new_messages, t)

      new_branch_id = Ecto.UUID.generate()

      new_branch = %{
        name: "",
        messages: new_messages,
        context: new_llm_context,
        parent_branch_id: t.current_branch_id,
        parent_message_id: message_id,
        active_task: nil,
        pending_messages: [],
        tool_status: nil,
        current_user_message: nil
      }

      branches = Map.put(t.branches, new_branch_id, new_branch)

      child_branches =
        Map.update(t.child_branches, message_id, [new_branch_id], fn children ->
          children ++ [new_branch_id]
        end)

      %{
        t
        | branches: branches,
          branch_ids: t.branch_ids ++ [new_branch_id],
          child_branches: child_branches,
          current_branch_id: new_branch_id
      }
    end
  end

  @doc """
  Marks a message as deleted in the current branch and rebuilds context.
  """
  def delete_message(%__MODULE__{} = t, message_id) do
    branch = t.branches[t.current_branch_id]

    updated_messages =
      Enum.map(branch.messages, fn msg ->
        if msg.id == message_id, do: Message.mark_deleted(msg), else: msg
      end)

    new_llm_context = rebuild_context_from_messages(updated_messages, t)

    updated_branch = %{branch | messages: updated_messages, context: new_llm_context}
    branches = Map.put(t.branches, t.current_branch_id, updated_branch)

    %{t | branches: branches}
  end

  defp rebuild_context_from_messages(messages, t) do
    messages
    |> Enum.drop(1)
    |> Enum.reject(&Message.deleted?/1)
    |> Enum.reduce(t.chat_module.reset_context(t.branches[t.current_branch_id].context), fn msg,
                                                                                            acc ->
      case msg.role do
        :user -> ReqLLM.Context.append(acc, ReqLLM.Context.user(msg.content))
        :assistant -> ReqLLM.Context.append(acc, ReqLLM.Context.assistant(msg.content))
        :system -> acc
      end
    end)
  end

  @doc """
  Builds a hierarchical representation of branches.
  """
  def build_tree(%__MODULE__{} = t) do
    adj =
      Enum.reduce(t.branch_ids, %{}, fn id, acc ->
        parent_id = t.branches[id].parent_branch_id
        Map.update(acc, parent_id, [id], fn children -> children ++ [id] end)
      end)

    build_node = fn build_node, id ->
      children = Map.get(adj, id, [])

      %{
        id: id,
        children: Enum.map(children, fn child_id -> build_node.(build_node, child_id) end)
      }
    end

    [build_node.(build_node, "main")]
  end

  @doc """
  Returns the messages of the active branch.
  """
  def get_current_messages(%__MODULE__{} = t) do
    t.branches[t.current_branch_id].messages
  end

  @doc """
  Returns the context of the active branch.
  """
  def get_current_context(%__MODULE__{} = t) do
    t.branches[t.current_branch_id].context
  end

  @doc """
  Checks if a branch is busy processing a message.
  """
  def busy?(%__MODULE__{} = t, branch_id) do
    not is_nil(t.branches[branch_id].active_task)
  end

  @doc """
  Sets the active task for a branch.
  """
  def set_active_task(%__MODULE__{} = t, branch_id, pid, user_message) do
    branch = t.branches[branch_id]
    updated_branch = %{branch | active_task: pid, current_user_message: user_message}
    branches = Map.put(t.branches, branch_id, updated_branch)
    %{t | branches: branches}
  end

  @doc """
  Clears the active task for a branch.
  """
  def clear_active_task(%__MODULE__{} = t, branch_id) do
    branch = t.branches[branch_id]
    updated_branch = %{branch | active_task: nil, current_user_message: nil, tool_status: nil}
    branches = Map.put(t.branches, branch_id, updated_branch)
    %{t | branches: branches}
  end

  @doc """
  Adds a message to the pending queue of a branch.
  """
  def enqueue_message(%__MODULE__{} = t, branch_id, message) do
    branch = t.branches[branch_id]
    updated_branch = %{branch | pending_messages: branch.pending_messages ++ [message]}
    branches = Map.put(t.branches, branch_id, updated_branch)
    %{t | branches: branches}
  end

  @doc """
  Pops the next message from the pending queue.
  """
  def dequeue_message(%__MODULE__{} = t, branch_id) do
    branch = t.branches[branch_id]

    case branch.pending_messages do
      [next | rest] ->
        updated_branch = %{branch | pending_messages: rest}
        branches = Map.put(t.branches, branch_id, updated_branch)
        {next, %{t | branches: branches}}

      [] ->
        {nil, t}
    end
  end

  @doc """
  Sets the tool status for a branch.
  """
  def set_tool_status(%__MODULE__{} = t, branch_id, status) do
    branch = t.branches[branch_id]
    updated_branch = %{branch | tool_status: status}
    branches = Map.put(t.branches, branch_id, updated_branch)
    %{t | branches: branches}
  end
end
