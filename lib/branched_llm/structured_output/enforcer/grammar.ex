defmodule BranchedLLM.StructuredOutput.Enforcer.Grammar do
  @moduledoc """
  Ollama / llama.cpp structured output enforcement via grammar-constrained decoding.

  The JSON schema is forwarded as a grammar specification in `provider_options`.
  Enforcement is at the sampling level — invalid tokens are masked during generation.
  """

  @behaviour BranchedLLM.StructuredOutput.Enforcer

  @impl true
  @doc """
  Injects the schema as a `grammar` (GBNF) parameter in provider_options.

  Note: Converting JSON Schema to GBNF is complex. For Ollama, the `format`
  parameter accepts a JSON Schema directly (Ollama >= 0.1.35). We pass it
  through provider_options so the Ollama provider can handle it natively.
  """
  def prepare_request(request, schema) do
    provider_options = Map.get(request, :provider_options, [])

    updated_provider_options =
      provider_options
      |> Keyword.put(:format, schema)

    Map.put(request, :provider_options, updated_provider_options)
  end

  @impl true
  @doc """
  For the Grammar path, the response is already valid JSON in the text.
  No special extraction is needed — the Validator handles it.
  """
  def extract_response(%{text: text}, _schema) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:error, :invalid_json}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  def extract_response(raw_response, _schema) do
    case Jason.decode(raw_response) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:error, :invalid_json}
      {:error, _} -> {:error, :invalid_json}
    end
  end
end
