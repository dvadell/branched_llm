defmodule BranchedLLM.UUID do
  @moduledoc false

  def generate do
    cond do
      Code.ensure_loaded?(Uniq.UUID) ->
        Uniq.UUID.uuid4()

      Code.ensure_loaded?(Ecto.UUID) ->
        Ecto.UUID.generate()

      true ->
        # Fallback to a simple random string if no UUID library is present
        :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    end
  end
end
