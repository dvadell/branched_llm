defmodule BranchedLLM.StructuredOutput.Validator do
  @moduledoc """
  Validates parsed JSON data against a JSON Schema using `ReqLLM.Schema.validate/2`.

  ReqLLM delegates to JSV (JSON Schema draft 2020-12) for map schemas,
  NimbleOptions for keyword schemas, and Zoi for Zoi structs.

  Also handles parsing raw text responses into Elixir maps before validation.
  """

  alias BranchedLLM.StructuredOutput.ValidationError

  @doc """
  Validates the raw LLM response text against the given schema.

  Parses the text as JSON, then validates the resulting map against the schema
  via `ReqLLM.Schema.validate/2`.

  Returns `{:ok, map}` on success or `{:error, %ValidationError{}}` on failure.
  """
  @spec validate(String.t(), map()) :: {:ok, map()} | {:error, ValidationError.t()}
  def validate(raw_text, schema) when is_binary(raw_text) and is_map(schema) do
    with {:ok, parsed} <- parse_json(raw_text),
         {:ok, _validated} <- ReqLLM.Schema.validate(parsed, schema) do
      {:ok, parsed}
    else
      {:error, :invalid_json} ->
        {:error,
         %ValidationError{
           message: "Response is not valid JSON",
           last_response: raw_text,
           validation_errors: ["Failed to parse response as JSON"]
         }}

      {:error, %_{} = error} ->
        {:error,
         %ValidationError{
           message: "Schema validation failed",
           last_response: raw_text,
           validation_errors: [inspect(error)]
         }}
    end
  end

  @doc """
  Validates a parsed Elixir map against the given schema.

  Uses `ReqLLM.Schema.validate/2` which supports JSON Schema maps,
  NimbleOptions keyword lists, and Zoi schema structs.

  Returns `:ok` or `{:error, %ValidationError{}}`.
  """
  @spec check_schema(map(), map()) :: :ok | {:error, ValidationError.t()}
  def check_schema(data, schema) when is_map(data) and is_map(schema) do
    case ReqLLM.Schema.validate(data, schema) do
      {:ok, _} ->
        :ok

      {:error, %_{} = error} ->
        {:error,
         %ValidationError{
           message: "Schema validation failed",
           validation_errors: [inspect(error)]
         }}
    end
  end

  defp parse_json(text) do
    case Jason.decode(text) do
      {:ok, parsed} when is_map(parsed) -> {:ok, parsed}
      {:ok, _other} -> {:error, :invalid_json}
      {:error, _} -> {:error, :invalid_json}
    end
  end
end
