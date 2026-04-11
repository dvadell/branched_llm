defmodule BranchedLLM.Message do
  @moduledoc """
  Generic AI message structure used across the system.
  """

  @derive {Jason.Encoder, only: [:id, :sender, :content, :deleted, :metadata, :timestamp]}
  defstruct [
    :id,
    :sender,
    :content,
    :timestamp,
    deleted: false,
    metadata: %{}
  ]

  @type sender :: :user | :assistant | :system | :tool
  @type t :: %__MODULE__{
          id: String.t(),
          sender: sender(),
          content: String.t(),
          timestamp: DateTime.t(),
          deleted: boolean(),
          metadata: map()
        }

  @doc """
  Creates a new message.
  """
  @spec new(sender(), String.t(), Keyword.t()) :: t()
  def new(sender, content, opts \\ []) do
    %__MODULE__{
      id: Keyword.get(opts, :id, Ecto.UUID.generate()),
      sender: sender,
      content: content,
      timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now()),
      deleted: Keyword.get(opts, :deleted, false),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end
end
