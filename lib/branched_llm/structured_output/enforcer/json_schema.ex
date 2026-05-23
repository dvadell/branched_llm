defmodule BranchedLLM.StructuredOutput.Enforcer.JsonSchema do
  @moduledoc """
  OpenAI structured output enforcement via `response_format: json_schema`.

  Passes the schema as `response_format: { type: "json_schema", json_schema: <schema> }`
  in provider_options. The model is token-constrained to produce valid output
  matching the schema exactly.
  """

  @behaviour BranchedLLM.StructuredOutput.Enforcer

  @impl true
  @doc """
  Injects `response_format` into the request's provider_options for OpenAI.
  """
  def prepare_request(request, schema) do
    response_format = %{
      type: "json_schema",
      json_schema: schema
    }

    provider_options = Map.get(request, :provider_options, [])

    updated_provider_options =
      Keyword.put(provider_options, :response_format, response_format)

    Map.put(request, :provider_options, updated_provider_options)
  end

  @impl true
  @doc """
  For the JsonSchema path, the response is already valid JSON in the text.
  No special extraction is needed — the Validator handles it.
  """
  def extract_response(%{text: text}, _schema) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  def extract_response(raw_response, _schema) do
    case Jason.decode(raw_response) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:error, _} -> {:error, :invalid_json}
    end
  end
end
