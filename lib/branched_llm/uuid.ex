defmodule BranchedLLM.UUID do
  @moduledoc false

  def generate(ensure_loaded? \\ &Code.ensure_loaded?/1) do
    cond do
      ensure_loaded?.(Uniq.UUID) ->
        Uniq.UUID.uuid4()

      ensure_loaded?.(Ecto.UUID) ->
        Ecto.UUID.generate()

      true ->
        :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    end
  end
end
