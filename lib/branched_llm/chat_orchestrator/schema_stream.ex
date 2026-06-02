defmodule BranchedLLM.ChatOrchestrator.SchemaStream do
  @moduledoc false

  alias BranchedLLM.ChatOrchestrator.StreamDispatcher
  alias BranchedLLM.LLM.StreamResult.{ContentResult, EmptyResult, ToolCallResult}
  alias BranchedLLM.StructuredOutput.ValidationError

  @default_schema_max_retries 2

  def run(params) do
    schema_max_retries = Map.get(params, :schema_max_retries, @default_schema_max_retries)
    max_attempts = schema_max_retries + 1
    do_run(params, 1, max_attempts)
  end

  defp do_run(params, attempt, max_attempts) do
    %{llm_context: context, chat_mod: chat_mod} = params

    case chat_mod.send_message_stream(context, schema_opts(params)) do
      {:ok, %ContentResult{} = result} ->
        {:ok, delta} = StreamDispatcher.dispatch(result, for_event(params))
        handle_content_result(delta, params, attempt, max_attempts)

      {:ok, %ToolCallResult{} = result} ->
        {:ok, delta} = StreamDispatcher.dispatch(result, for_event(params))
        handle_tool_call_result(delta, result, params, attempt, max_attempts)

      {:ok, %EmptyResult{}} ->
        retry_on_empty(params, attempt, max_attempts)

      {:error, reason} ->
        retry_on_error(params, attempt, max_attempts, reason)
    end
  end

  defp retry_on_empty(params, attempt, max_attempts) do
    if attempt < max_attempts do
      do_run(params, attempt + 1, max_attempts)
    else
      {:error, "The AI did not return a response. Please try again."}
    end
  end

  defp retry_on_error(params, attempt, max_attempts, _reason) do
    if attempt < max_attempts do
      do_run(params, attempt + 1, max_attempts)
    else
      {:error, "The AI did not return a response. Please try again."}
    end
  end

  # ContentResult with empty stream produces full_text == ""
  defp handle_content_result(
         %{dispatch_tags: %{full_text: ""}},
         params,
         attempt,
         max_attempts
       ) do
    retry_on_empty(params, attempt, max_attempts)
  end

  defp handle_content_result(
         %{dispatch_tags: %{full_text: text}},
         params,
         attempt,
         max_attempts
       ) do
    schema = Map.fetch!(params, :schema)

    case validate_with_req_llm(text, schema) do
      {:ok, validated} ->
        params.on_event.({:llm_end, params.branch_id, validated})
        :ok

      {:error, %ValidationError{}} ->
        if attempt < max_attempts do
          do_run(params, attempt + 1, max_attempts)
        else
          {:error,
           %ValidationError{
             message: "Schema validation failed after #{max_attempts} attempts",
             last_response: text,
             validation_errors: ["Last response failed schema validation"]
           }}
        end
    end
  end

  defp handle_tool_call_result(
         %{dispatch_tags: %{context: context, tool_calls: tool_calls}},
         _result,
         params,
         attempt,
         max_attempts
       ) do
    if structured_output_tool_call?(tool_calls) do
      handle_structured_output_tool_call(tool_calls, params, context, attempt, max_attempts)
    else
      next =
        BranchedLLM.ToolHandler.update_params_with_tool_results(tool_calls, %{
          params
          | llm_context: context
        })

      __MODULE__.run(next)
    end
  end

  defp structured_output_tool_call?(tool_calls) do
    Enum.any?(tool_calls, fn tool_call ->
      ReqLLM.ToolCall.name(tool_call) == "__structured_output__"
    end)
  end

  defp handle_structured_output_tool_call(tool_calls, params, context, attempt, max_attempts) do
    structured_call =
      Enum.find(tool_calls, fn tc ->
        ReqLLM.ToolCall.name(tc) == "__structured_output__"
      end)

    validate_and_emit_structured_call(structured_call, params, context, attempt, max_attempts)
  end

  defp validate_and_emit_structured_call(call, params, context, attempt, max_attempts) do
    args_map = ReqLLM.ToolCall.args_map(call) || %{}
    schema = Map.fetch!(params, :schema)

    case validate_structured_output(args_map, schema) do
      :ok ->
        params.on_event.({:llm_end, params.branch_id, args_map})
        :ok

      {:error, %ValidationError{}} ->
        if attempt < max_attempts do
          do_run(%{params | llm_context: context}, attempt + 1, max_attempts)
        else
          {:error,
           %ValidationError{
             message: "Schema validation failed after #{max_attempts} attempts",
             last_response: nil,
             validation_errors: ["Structured output tool call args failed schema validation"]
           }}
        end
    end
  end

  defp validate_structured_output(args_map, schema) do
    case ReqLLM.Schema.validate(args_map, schema) do
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

  defp validate_with_req_llm(text, schema) do
    with {:ok, parsed} <- parse_json(text),
         {:ok, _validated} <- ReqLLM.Schema.validate(parsed, schema) do
      {:ok, parsed}
    else
      {:error, :invalid_json} ->
        {:error,
         %ValidationError{
           message: "Response is not valid JSON",
           last_response: text,
           validation_errors: ["Failed to parse response as JSON"]
         }}

      {:error, %_{} = error} ->
        {:error,
         %ValidationError{
           message: "Schema validation failed",
           last_response: text,
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

  defp schema_opts(params) do
    schema = Map.fetch!(params, :schema)
    provider_options = BranchedLLM.ChatOrchestrator.schema_provider_options(schema)

    base_opts =
      []
      |> Keyword.put(:tools, Map.get(params, :llm_tools, []))
      |> Keyword.put(:schema, schema)
      |> Keyword.put(:provider_options, provider_options)

    model = params.chat_mod.default_model()
    provider = resolve_provider(model)

    if provider == :anthropic do
      synthetic_tool = build_synthetic_tool(schema)
      existing_tools = Keyword.get(base_opts, :tools, [])
      updated_tools = existing_tools ++ [synthetic_tool]

      base_opts
      |> Keyword.put(:tools, updated_tools)
      |> Keyword.put(:tool_choice, %{
        "type" => "function",
        "function" => %{"name" => "__structured_output__"}
      })
    else
      base_opts
    end
  end

  defp resolve_provider(%LLMDB.Model{provider: provider}) when is_atom(provider) do
    provider
  end

  defp resolve_provider(model_string) when is_binary(model_string) do
    case String.split(model_string, ":", parts: 2) do
      [provider_str, _model_id] ->
        try do
          String.to_existing_atom(provider_str)
        rescue
          ArgumentError -> :unknown
        end

      _ ->
        :unknown
    end
  end

  defp build_synthetic_tool(schema) do
    %{
      "type" => "function",
      "function" => %{
        "name" => "__structured_output__",
        "description" => "Respond with structured data matching the provided schema.",
        "parameters" => schema
      }
    }
  end

  defp for_event(params) do
    %{
      on_event: Map.fetch!(params, :on_event),
      branch_id: Map.fetch!(params, :branch_id),
      tool_usage_counts: Map.get(params, :tool_usage_counts, %{}),
      dispatch_tags: nil
    }
  end
end
