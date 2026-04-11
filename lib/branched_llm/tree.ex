defmodule BranchedLLM.Tree do
  @moduledoc """
  A pure functional tree structure for managing branched LLM conversations.
  """

  alias BranchedLLM.Message
  alias ReqLLM.Context

  @derive {Jason.Encoder, only: [:branches, :branch_ids, :current_branch_id, :child_branches, :chat_module]}
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
          context: Context.t(),
          parent_branch_id: String.t() | nil,
          parent_message_id: String.t() | nil,
          pending_messages: [String.t()],
          metadata: map()
        }

  @type t :: %__MODULE__{
          branches: %{String.t() => branch_metadata()},
          branch_ids: [String.t()],
          current_branch_id: String.t(),
          child_branches: %{String.t() => [String.t()]},
          chat_module: module()
        }

  @doc """
  Initializes a new tree.
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
          branch_id: initial_branch_id,
          name: "Main Conversation",
          messages: initial_messages,
          context: initial_context,
          parent_branch_id: nil,
          parent_message_id: nil,
          pending_messages: [],
          metadata: %{}
        }
      }
    }
  end

  @doc """
  Changes the active branch.
  """
  def switch_branch(%__MODULE__{} = t, branch_id) do
    if Map.has_key?(t.branches, branch_id), do: %{t | current_branch_id: branch_id}, else: t
  end

  @doc """
  Adds a user message to the current branch.
  """
  def add_user_message(%__MODULE__{} = t, content) do
    user_message = Message.new(:user, content)
    branch = t.branches[t.current_branch_id]

    name = if branch.name == "" or branch.name == "Main Conversation", do: generate_name(content), else: branch.name

    updated_branch = %{branch | name: name, messages: branch.messages ++ [user_message]}
    %{t | branches: Map.put(t.branches, t.current_branch_id, updated_branch)}
  end

  @doc """
  Updates a message's content and rebuilds the branch context.
  """
  def update_message(%__MODULE__{} = t, message_id, new_content) do
    branch = t.branches[t.current_branch_id]

    updated_messages =
      Enum.map(branch.messages, fn msg ->
        if msg.id == message_id, do: %{msg | content: new_content}, else: msg
      end)

    rebuild_context(t, updated_messages)
  end

  @doc """
  Deletes a message (marks it as deleted) and rebuilds the branch context.
  """
  def delete_message(%__MODULE__{} = t, message_id) do
    branch = t.branches[t.current_branch_id]

    updated_messages =
      Enum.map(branch.messages, fn msg ->
        if msg.id == message_id, do: %{msg | deleted: true}, else: msg
      end)

    rebuild_context(t, updated_messages)
  end

  @doc """
  Inserts a message after a specific message and rebuilds context.
  """
  def insert_message(%__MODULE__{} = t, after_message_id, new_message) do
    branch = t.branches[t.current_branch_id]
    idx = Enum.find_index(branch.messages, fn msg -> msg.id == after_message_id end)

    if is_nil(idx) do
      t
    else
      {head, tail} = Enum.split(branch.messages, idx + 1)
      updated_messages = head ++ [new_message] ++ tail
      rebuild_context(t, updated_messages)
    end
  end

  defp rebuild_context(t, updated_messages) do
    branch = t.branches[t.current_branch_id]
    new_context = rebuild_context_from_messages(updated_messages, t)
    updated_branch = %{branch | messages: updated_messages, context: new_context}
    %{t | branches: Map.put(t.branches, t.current_branch_id, updated_branch)}
  end

  @doc """
  Creates a new branch from a message ID.
  """
  def branch_off(%__MODULE__{} = t, message_id) do
    messages = t.branches[t.current_branch_id].messages
    idx = Enum.find_index(messages, fn msg -> msg.id == message_id end)

    if is_nil(idx) do
      t
    else
      new_messages = Enum.slice(messages, 0..idx)
      new_branch_id = Ecto.UUID.generate()
      new_context = rebuild_context_from_messages(new_messages, t)

      new_branch = %{
        branch_id: new_branch_id,
        name: generate_name_from_messages(new_messages),
        messages: new_messages,
        context: new_context,
        parent_branch_id: t.current_branch_id,
        parent_message_id: message_id,
        pending_messages: [],
        metadata: %{}
      }

      %{
        t
        | branches: Map.put(t.branches, new_branch_id, new_branch),
          branch_ids: t.branch_ids ++ [new_branch_id],
          child_branches: Map.update(t.child_branches, message_id, [new_branch_id], &[new_branch_id | &1]),
          current_branch_id: new_branch_id
      }
    end
  end

  @doc """
  Prunes a branch and all its descendants.
  """
  def prune_branch(%__MODULE__{} = t, branch_id) do
    if branch_id == "main" do
      t
    else
      descendants = get_all_descendants(t, branch_id)
      to_remove = [branch_id | descendants]

      updated_branches = Map.drop(t.branches, to_remove)
      updated_branch_ids = t.branch_ids -- to_remove

      updated_child_branches = cleanup_child_branches(t.child_branches, t.branches[branch_id])

      new_current_id = if t.current_branch_id in to_remove, do: "main", else: t.current_branch_id

      %{
        t
        | branches: updated_branches,
          branch_ids: updated_branch_ids,
          child_branches: updated_child_branches,
          current_branch_id: new_current_id
      }
    end
  end

  defp cleanup_child_branches(child_branches, branch_metadata) do
    case branch_metadata.parent_message_id do
      nil -> child_branches
      msg_id -> Map.update(child_branches, msg_id, [], fn children -> children -- [branch_metadata.branch_id] end)
    end
  end

  @doc """
  Exports the tree to a plain map for serialization.
  """
  def to_map(%__MODULE__{} = t), do: Map.from_struct(t)

  @doc """
  Hydrates a tree from a map.
  """
  def from_map(map, chat_module) when is_map(map) do
    struct(__MODULE__, Map.put(map, :chat_module, chat_module))
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

  # Helper functions

  defp generate_name(content) do
    snippet = content |> String.slice(0, 30) |> String.trim()
    if String.length(content) > 30, do: snippet <> "...", else: snippet
  end

  defp generate_name_from_messages(messages) do
    case Enum.reverse(messages) |> Enum.find(fn m -> m.sender == :user end) do
      nil -> ""
      msg -> generate_name(msg.content)
    end
  end

  defp rebuild_context_from_messages(messages, t) do
    # Assuming index 0 is system prompt which shouldn't be touched by reset
    system_prompt_msg = List.first(messages)

    messages
    |> Enum.drop(1)
    |> Enum.filter(fn msg -> !Map.get(msg, :deleted, false) end)
    |> Enum.reduce(t.chat_module.new_context(system_prompt_msg.content), fn msg, acc ->
      case msg.sender do
        :user -> Context.append(acc, Context.user(msg.content))
        :assistant -> Context.append(acc, Context.assistant(msg.content))
        :tool -> acc
        _ -> acc
      end
    end)
  end

  defp get_all_descendants(t, branch_id) do
    direct_children =
      t.branches[branch_id].messages
      |> Enum.flat_map(fn msg -> Map.get(t.child_branches, msg.id, []) end)
      |> Enum.filter(fn child_id -> t.branches[child_id].parent_branch_id == branch_id end)

    direct_children ++ Enum.flat_map(direct_children, &get_all_descendants(t, &1))
  end
end
