defmodule BranchedLLM.StructuredOutput.Validator do
  @moduledoc """
  Validates parsed JSON data against a JSON Schema using `ex_json_schema`.

  Also handles parsing raw text responses into Elixir maps before validation.
  """

  alias BranchedLLM.StructuredOutput.ValidationError

  @doc """
  Validates the raw LLM response text against the given schema.

  Parses the text as JSON, then validates the resulting map against the schema.
  Returns `{:ok, map}` on success or `{:error, %ValidationError{}}` on failure.
  """
  @spec validate(String.t(), map()) :: {:ok, map()} | {:error, ValidationError.t()}
  def validate(raw_text, schema) when is_binary(raw_text) and is_map(schema) do
    with {:ok, parsed} <- parse_json(raw_text),
         :ok <- check_schema(parsed, schema) do
      {:ok, parsed}
    else
      {:error, %ValidationError{}} = error ->
        error

      {:error, :invalid_json} ->
        {:error,
         %ValidationError{
           message: "Response is not valid JSON",
           last_response: raw_text,
           validation_errors: ["Failed to parse response as JSON"]
         }}
    end
  end

  @doc """
  Validates a parsed Elixir map against the given schema.

  Returns `:ok` or `{:error, validation_errors}` where validation_errors
  is a list of human-readable error strings.
  """
  @spec check_schema(map(), map()) :: :ok | {:error, ValidationError.t()}
  def check_schema(data, schema) when is_map(data) and is_map(schema) do
    resolved_schema = resolve_schema(schema)

    case ExJsonSchema.Validator.validate(resolved_schema, data) do
      :ok ->
        :ok

      {:error, errors} ->
        error_messages = format_errors(errors)

        {:error,
         %ValidationError{
           message: "Schema validation failed",
           validation_errors: error_messages
         }}
    end
  end

  defp parse_json(text) do
    case Jason.decode(text) do
      {:ok, parsed} when is_map(parsed) ->
        {:ok, parsed}

      {:ok, _other} ->
        {:error, :invalid_json}

      {:error, _} ->
        {:error, :invalid_json}
    end
  end

  defp resolve_schema(schema) do
    ExJsonSchema.Schema.resolve(schema)
  end

  defp format_errors(errors) do
    Enum.map(errors, fn
      {path, message} -> "#{path}: #{message}"
      message when is_binary(message) -> message
      other -> inspect(other)
    end)
  end
end
