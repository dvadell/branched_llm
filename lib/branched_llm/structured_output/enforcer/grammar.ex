defmodule BranchedLLM.StructuredOutput.Enforcer.Grammar do
  @moduledoc """
  Ollama structured output enforcement via the OpenAI-compatible `response_format`.

  The JSON schema is forwarded as `response_format` in `provider_options`, which
  the Ollama provider (req_llm >= 1.13.0) natively supports through its
  `/v1/chat/completions` endpoint. Enforcement is at the sampling level —
  invalid tokens are masked during generation.
  """

  @behaviour BranchedLLM.StructuredOutput.Enforcer

  @impl true
  @doc """
  Injects the schema as `response_format` (json_schema mode) in provider_options.

  The Ollama provider's `/v1` endpoint accepts the same `response_format` structure
  as OpenAI: `%{type: "json_schema", json_schema: %{name: ..., schema: ...}}`.
  """
  def prepare_request(request, schema) do
    response_format = %{
      type: "json_schema",
      json_schema: schema
    }

    provider_options = Map.get(request, :provider_options, [])

    updated_provider_options =
      provider_options
      |> Keyword.put(:response_format, response_format)

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
