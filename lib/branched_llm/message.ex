defmodule BranchedLLM.Message do
  @moduledoc """
  A formal, immutable message structure for AI conversations.

  This struct represents a single message in a conversation, decoupled from
  any specific domain. It contains the sender role, content, and optional metadata.

  ## Fields

    * `:role` - The role of the sender (`:user`, `:assistant`, or `:system`)
    * `:content` - The text content of the message
    * `:id` - A unique identifier for the message
    * `:metadata` - A map of optional metadata (e.g., `deleted: true`, tool calls, etc.)

  ## Backward Compatibility

  The `sender` field is available as a read-only derived field via `sender/1` for
  templates that access `message.sender`. Internally, `:role` is the canonical field.

  ## Examples

      iex> BranchedLLM.Message.new(:user, "Hello!")
      %BranchedLLM.Message{role: :user, content: "Hello", id: id, metadata: %{}}

  """

  @enforce_keys [:role, :content, :id]
  defstruct [:role, :sender, :content, :id, metadata: %{}]

  @type role :: :user | :assistant | :system
  @type t :: %__MODULE__{
          role: role(),
          sender: role(),
          content: String.t(),
          id: String.t(),
          metadata: map()
        }

  @doc """
  Creates a new message with the given role and content.

  An optional `id` can be provided; otherwise, one is generated.
  """
  @spec new(role(), String.t(), String.t() | nil, map()) :: t()
  def new(role, content, id \\ nil, metadata \\ %{}) do
    %__MODULE__{
      role: role,
      sender: role,
      content: content,
      id: id || Ecto.UUID.generate(),
      metadata: metadata
    }
  end

  @doc """
  Marks a message as deleted by setting `metadata.deleted` to `true`.
  """
  @spec mark_deleted(t()) :: t()
  def mark_deleted(%__MODULE__{} = msg) do
    %{msg | metadata: Map.put(msg.metadata, :deleted, true)}
  end

  @doc """
  Returns whether a message is marked as deleted.
  """
  @spec deleted?(t()) :: boolean()
  def deleted?(%__MODULE__{metadata: %{deleted: true}}), do: true
  def deleted?(%__MODULE__{}), do: false

  @doc """
  Converts a legacy message map to a `BranchedLLM.Message` struct.
  """
  @spec from_map(map()) :: t()
  def from_map(%{sender: sender, content: content, id: id, deleted: deleted} = map) do
    metadata = Map.get(map, :metadata, %{})
    metadata = if deleted, do: Map.put(metadata, :deleted, true), else: metadata

    %__MODULE__{
      role: sender,
      sender: sender,
      content: content,
      id: id,
      metadata: metadata
    }
  end

  def from_map(%{sender: sender, content: content, id: id}) do
    %__MODULE__{
      role: sender,
      sender: sender,
      content: content,
      id: id,
      metadata: %{}
    }
  end

  @doc """
  Returns a map representation compatible with legacy message formats.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = msg) do
    %{
      sender: msg.role,
      content: msg.content,
      id: msg.id,
      deleted: Map.get(msg.metadata, :deleted, false)
    }
  end
end
