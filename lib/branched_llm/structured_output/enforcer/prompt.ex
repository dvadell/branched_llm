defmodule BranchedLLM.StructuredOutput.Enforcer.Prompt do
  @moduledoc """
  Fallback structured output enforcement via prompt injection.

  For unknown or unsupported providers, the schema is serialised and appended
  to the system prompt with an instruction to respond only in valid JSON
  matching the schema. No token-level guarantee — validation and retry are
  especially important in this path.
  """

  @behaviour BranchedLLM.StructuredOutput.Enforcer

  @impl true
  @doc """
  Appends schema instructions to the system prompt in the request.
  """
  def prepare_request(request, schema) do
    schema_json = Jason.encode!(schema, pretty: true)

    instruction = """

    IMPORTANT: You must respond with valid JSON matching this schema:
    ```json
    #{schema_json}
    ```

    Respond ONLY with valid JSON matching the schema above. Do not include any other text, explanation, or markdown formatting outside the JSON object.
    """

    context = Map.get(request, :context)
    system_prompt = Map.get(request, :system_prompt, "")

    request
    |> Map.put(:system_prompt, system_prompt <> instruction)
    |> Map.put(:context, context)
  end

  @impl true
  @doc """
  For the Prompt path, the response is text that should contain JSON.
  Attempts to extract JSON from the text, stripping markdown fences if present.
  """
  def extract_response(%{text: text}, _schema) when is_binary(text) do
    extracted = strip_json_fences(text)

    case Jason.decode(extracted) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:error, :invalid_json}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  def extract_response(raw_response, _schema) when is_binary(raw_response) do
    extracted = strip_json_fences(raw_response)

    case Jason.decode(extracted) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:error, :invalid_json}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  def extract_response(_raw_response, _schema) do
    {:error, :unsupported_response_format}
  end

  @doc """
  Strips markdown code fences (```json ... ```) from the response text.
  """
  @spec strip_json_fences(String.t()) :: String.t()
  def strip_json_fences(text) do
    text
    |> String.replace(~r/^```(?:json)?\s*\n?/s, "")
    |> String.replace(~r/\n?```\s*$/s, "")
    |> String.trim()
  end
end
