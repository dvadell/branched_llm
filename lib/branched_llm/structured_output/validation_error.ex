defmodule BranchedLLM.StructuredOutput.ValidationError do
  @moduledoc """
  Error struct returned when schema validation fails after all retries are exhausted.

  Emitted via the `:llm_error` event when the LLM response cannot be made
  to conform to the requested JSON schema within the retry limit.
  """

  @enforce_keys [:message]
  defstruct [:message, :last_response, :validation_errors]

  @type t :: %__MODULE__{
          message: String.t(),
          last_response: String.t() | nil,
          validation_errors: [String.t()]
        }
end
