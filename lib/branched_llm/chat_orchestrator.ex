defmodule BranchedLLM.ChatOrchestrator do
  @moduledoc """
  Orchestrates the LLM request/response lifecycle, including tool calls and streaming.

  This module is **domain-agnostic** — it knows nothing about education, students, or teachers.
  It communicates with a caller process (e.g., a LiveView) via a well-defined message protocol.

  ## Message Protocol

  The orchestrator sends the following messages through the `on_event` function,
  typically to the caller pid:

  * `{:llm_chunk, branch_id, chunk}` — A streaming text chunk from the LLM
  * `{:llm_end, branch_id, full_text}` — The stream is complete; `full_text` is the full
    accumulated text of the assistant's response. When `schema:` is provided, the third
    element is the validated Elixir map instead of the raw text.
  * `{:llm_status, branch_id, status}` — A status update (e.g., "Thinking...", "Using calculator...")
  * `{:llm_error, branch_id, error_message}` — An error occurred during the LLM request.
    When schema validation fails after all retries, `error_message` is a
    `%BranchedLLM.StructuredOutput.ValidationError{}` struct.
  * `{:update_tool_usage_counts, counts}` — Updated tool usage counts for the caller to track

  The caller may also send messages back (e.g., to cancel a task), but those are handled
  externally via the `active_task` PID in `BranchedChat`.

  ## Structured Output

  When `schema:` is provided in the params, the orchestrator validates the LLM response
  against the schema and retries on failure (up to `schema_max_retries` times, default 2).
  On success, `:llm_end` carries the validated map. On exhaustion, `:llm_error` carries
  a `ValidationError` struct.

  ## Example

      caller_pid = self()

      params = %{
        llm_context: context,
        on_event: fn event -> send(caller_pid, event) end,
        llm_tools: [calculator_tool],
        chat_mod: BranchedLLM.Chat,
        tool_usage_counts: %{},
        branch_id: "main",
        schema: %{
          "type" => "object",
          "properties" => %{
            "invoice_number" => %{"type" => "string"},
            "amount" => %{"type" => "number"}
          },
          "required" => ["invoice_number", "amount"]
        },
        schema_max_retries: 3
      }

      BranchedLLM.ChatOrchestrator.run(params)
  """

  use Retry

  require Logger

  alias BranchedLLM.LLM.StreamResult.{ContentResult, EmptyResult, ToolCallResult}
  alias BranchedLLM.LLMErrorFormatter
  alias BranchedLLM.StructuredOutput.Enforcer
  alias BranchedLLM.StructuredOutput.ValidationError
  alias BranchedLLM.StructuredOutput.Validator
  alias BranchedLLM.ToolHandler

  alias ReqLLM.Context
  alias ReqLLM.StreamResponse.MetadataHandle

  @default_schema_max_retries 2

  @type llm_call_params :: %{
          required(:llm_context) => ReqLLM.Context.t(),
          required(:on_event) => fun(),
          required(:llm_tools) => list(),
          required(:chat_mod) => module(),
          required(:tool_usage_counts) => map(),
          required(:branch_id) => String.t(),
          optional(:schema) => map() | nil,
          optional(:schema_max_retries) => non_neg_integer() | nil
        }

  @doc """
  Starts the LLM request process in a separate task.

  The task communicates with the caller via messages defined in the module doc.
  """
  @spec run(llm_call_params()) :: {:ok, pid()}
  def run(params) do
    Task.start(fn ->
      result =
        retry with: constant_backoff(100) |> Stream.take(10) do
          case process_llm_request(params) do
            :ok ->
              :ok

            {:error, reason} ->
              params.on_event.({:llm_status, params.branch_id, "Retrying..."})
              {:error, reason}
          end
        after
          result -> result
        else
          error -> error
        end

      case result do
        :ok -> :ok
        {:error, reason} -> params.on_event.({:llm_error, params.branch_id, reason})
      end
    end)
  end

  @spec process_llm_request(llm_call_params()) :: :ok | {:error, String.t()}
  defp process_llm_request(
         %{
           llm_context: llm_context,
           on_event: _event_fn,
           llm_tools: _llm_tools,
           chat_mod: chat_mod
         } = llm_call_params
       ) do
    stream_opts = build_stream_opts(llm_call_params)

    case chat_mod.send_message_stream(llm_context, stream_opts) do
      {:ok, %ContentResult{} = result} ->
        handle_content_result(result, llm_call_params)

      {:ok, %ToolCallResult{tool_calls: tool_calls} = result} ->
        if structured_output_tool_call?(tool_calls) do
          handle_structured_output_tool_call(result, llm_call_params)
        else
          handle_tool_call_result(result, llm_call_params)
        end

      {:ok, %EmptyResult{}} ->
        {:error, "The AI did not return a response. Please try again."}

      {:error, reason} ->
        {:error, "Error: #{inspect(reason)}"}
    end
  rescue
    exception ->
      {:error, LLMErrorFormatter.format(exception)}
  end

  defp build_stream_opts(llm_call_params) do
    schema = Map.get(llm_call_params, :schema)
    llm_tools = Map.get(llm_call_params, :llm_tools, [])

    base_opts = [tools: llm_tools]

    opts_with_schema =
      if schema do
        Keyword.put(base_opts, :schema, schema)
      else
        base_opts
      end

    if schema do
      model = resolve_model(llm_call_params)
      provider = Enforcer.resolve_provider(model)
      provider_opts = Enforcer.prepare_request(provider, %{}, schema)

      case Map.get(provider_opts, :provider_options) do
        nil ->
          opts_with_schema

        po when is_list(po) ->
          Keyword.put(opts_with_schema, :provider_options, po)

        po when is_map(po) ->
          Keyword.put(opts_with_schema, :provider_options, Map.to_list(po))
      end
    else
      opts_with_schema
    end
  end

  defp resolve_model(%{chat_mod: chat_mod}) do
    chat_mod.default_model()
  end

  @spec handle_content_result(ContentResult.t(), llm_call_params()) :: :ok | {:error, String.t()}
  defp handle_content_result(
         %ContentResult{stream: stream_response},
         %{on_event: on_event_fn, tool_usage_counts: tool_usage_counts, branch_id: branch_id} =
           llm_call_params
       ) do
    schema = Map.get(llm_call_params, :schema)

    case process_stream(stream_response, on_event_fn, tool_usage_counts, branch_id) do
      {true, full_text} ->
        if schema do
          handle_schema_validation(full_text, schema, llm_call_params)
        else
          on_event_fn.({:llm_end, branch_id, full_text})
          :ok
        end

      {false, _} ->
        {:error, "The AI did not return a response. Please try again."}
    end
  end

  @spec handle_structured_output_tool_call(ToolCallResult.t(), llm_call_params()) ::
          :ok | {:error, String.t()}
  defp handle_structured_output_tool_call(
         %ToolCallResult{tool_calls: tool_calls},
         llm_call_params
       ) do
    synthetic_name = Enforcer.structured_output_tool_name()

    case Enum.find(tool_calls, &ReqLLM.ToolCall.matches_name?(&1, synthetic_name)) do
      nil ->
        {:error, "Structured output tool call not found"}

      tool_call ->
        args = ReqLLM.ToolCall.args_map(tool_call) || %{}
        validate_structured_output_args(args, llm_call_params)
    end
  end

  @spec validate_structured_output_args(map(), llm_call_params()) ::
          :ok | {:error, String.t()}
  defp validate_structured_output_args(
         args,
         %{on_event: on_event_fn, branch_id: branch_id} = llm_call_params
       ) do
    schema = Map.get(llm_call_params, :schema)

    if schema do
      validate_structured_output_with_schema(args, schema, llm_call_params)
    else
      on_event_fn.({:llm_end, branch_id, args})
      :ok
    end
  end

  @spec validate_structured_output_with_schema(map(), map(), llm_call_params()) ::
          :ok | {:error, String.t()}
  defp validate_structured_output_with_schema(args, schema, llm_call_params) do
    case Validator.check_schema(args, schema) do
      :ok ->
        %{on_event: on_event_fn, branch_id: branch_id} = llm_call_params
        on_event_fn.({:llm_end, branch_id, args})
        :ok

      {:error, %ValidationError{} = error} ->
        max_retries = schema_max_retries(llm_call_params)

        retry_with_schema_validation(
          args,
          error,
          llm_call_params,
          max_retries,
          1
        )
    end
  end

  @spec handle_tool_call_result(ToolCallResult.t(), llm_call_params()) ::
          :ok | {:error, String.t()}
  defp handle_tool_call_result(
         %ToolCallResult{tool_calls: tool_calls, context: context},
         llm_call_params
       ) do
    updated_llm_call_params = %{llm_call_params | llm_context: context}

    next_llm_call_params =
      handle_tool_call_execution(tool_calls, updated_llm_call_params)

    process_llm_request(next_llm_call_params)
  end

  @spec handle_tool_call_execution(list(), llm_call_params()) :: llm_call_params()
  defp handle_tool_call_execution(
         tool_calls,
         %{
           llm_context: llm_context,
           llm_tools: llm_tools,
           chat_mod: chat_mod,
           tool_usage_counts: tool_usage_counts,
           on_event: on_event_fn,
           branch_id: branch_id
         } = llm_call_params
       ) do
    tool_names = Enum.map_join(tool_calls, ", ", &ReqLLM.ToolCall.name/1)

    on_event_fn.({:llm_status, branch_id, "Using #{tool_names}..."})

    {tool_calls_to_execute, tool_results_for_limited_tools, new_tool_usage_counts} =
      Enum.reduce(tool_calls, {[], [], tool_usage_counts}, fn tool_call,
                                                              {exec_acc, limited_acc, counts_acc} ->
        tool_name = ReqLLM.ToolCall.name(tool_call)
        tool_name_atom = String.to_atom(tool_name)
        current_count = Map.get(counts_acc, tool_name_atom, 0)

        if current_count < 10 do
          {[tool_call | exec_acc], limited_acc,
           Map.put(counts_acc, tool_name_atom, current_count + 1)}
        else
          tool_result =
            Context.tool_result(tool_call.id, "Tool limit reached. Summarize with what you have")

          {exec_acc, [tool_result | limited_acc], counts_acc}
        end
      end)

    tool_calls_to_execute = Enum.reverse(tool_calls_to_execute)
    tool_results_for_limited_tools = Enum.reverse(tool_results_for_limited_tools)

    llm_context_after_tool_handling =
      if Enum.empty?(tool_calls_to_execute) do
        Context.append(llm_context, Context.assistant("", tool_calls: tool_calls))
      else
        llm_context_with_assistant_tool_calls =
          Context.append(llm_context, Context.assistant("", tool_calls: tool_calls_to_execute))

        ToolHandler.handle_tool_calls(
          tool_calls_to_execute,
          llm_context_with_assistant_tool_calls,
          llm_tools,
          chat_mod
        )
      end

    updated_llm_context =
      Enum.reduce(tool_results_for_limited_tools, llm_context_after_tool_handling, fn tr, acc ->
        Context.append(acc, tr)
      end)

    %{
      llm_call_params
      | llm_context: updated_llm_context,
        tool_usage_counts: new_tool_usage_counts
    }
  end

  # --- Stream Processing ---

  @spec process_stream(
          ReqLLM.StreamResponse.t(),
          any(),
          map(),
          String.t()
        ) :: {boolean(), String.t()}
  defp process_stream(
         stream_response,
         on_event_fn,
         tool_usage_counts,
         branch_id
       ) do
    on_event_fn.({:update_tool_usage_counts, tool_usage_counts})

    start_time = :erlang.monotonic_time(:millisecond)

    {sent_any_chunks, full_text} =
      stream_response
      |> ReqLLM.StreamResponse.tokens()
      |> Enum.reduce_while({false, ""}, fn chunk, {_, acc} ->
        on_event_fn.({:llm_chunk, branch_id, chunk})
        {:cont, {true, acc <> chunk}}
      end)

    end_time = :erlang.monotonic_time(:millisecond)

    Logger.info("LLM streaming of answer took #{end_time - start_time}ms")

    metadata = MetadataHandle.await(stream_response.metadata_handle)
    Logger.info("LLM stream complete metadata: #{inspect(metadata)}")

    {sent_any_chunks, full_text}
  end

  # --- Schema Validation & Retry ---

  defp handle_schema_validation(full_text, schema, llm_call_params) do
    %{on_event: on_event_fn, branch_id: branch_id} = llm_call_params

    case Validator.validate(full_text, schema) do
      {:ok, validated_map} ->
        on_event_fn.({:llm_end, branch_id, validated_map})
        :ok

      {:error, %ValidationError{} = error} ->
        max_retries = schema_max_retries(llm_call_params)

        retry_with_schema_validation(
          full_text,
          error,
          llm_call_params,
          max_retries,
          1
        )
    end
  end

  defp retry_with_schema_validation(_last_response, _error, llm_call_params, max_retries, attempt)
       when attempt > max_retries do
    %{on_event: on_event_fn, branch_id: branch_id, schema: schema} = llm_call_params

    case Validator.validate("", schema) do
      {:error, %ValidationError{validation_errors: _} = final_error} ->
        final_error = %{
          final_error
          | message: "Schema validation failed after #{max_retries + 1} attempts"
        }

        on_event_fn.({:llm_error, branch_id, final_error})
        {:error, "Schema validation failed after #{max_retries + 1} attempts"}

      _ ->
        on_event_fn.(
          {:llm_error, branch_id,
           %ValidationError{
             message: "Schema validation failed after #{max_retries + 1} attempts"
           }}
        )

        {:error, "Schema validation failed after #{max_retries + 1} attempts"}
    end
  end

  defp retry_with_schema_validation(last_response, error, llm_call_params, max_retries, attempt) do
    %{on_event: on_event_fn, branch_id: branch_id, llm_context: llm_context} =
      llm_call_params

    on_event_fn.(
      {:llm_status, branch_id, "Retrying schema validation (attempt #{attempt + 1})..."}
    )

    retry_prompt = build_retry_prompt(last_response, error)

    retry_context =
      llm_context
      |> Context.append(Context.assistant(last_response))
      |> Context.append(Context.user(retry_prompt))

    retry_params = %{llm_call_params | llm_context: retry_context}

    # Make a new LLM call with the retry context
    stream_opts = build_stream_opts(retry_params)

    case retry_params.chat_mod.send_message_stream(retry_context, stream_opts) do
      {:ok, %ContentResult{} = result} ->
        retry_handle_content_result(
          result,
          last_response,
          error,
          llm_call_params,
          max_retries,
          attempt
        )

      {:ok, %ToolCallResult{tool_calls: tool_calls}} ->
        retry_handle_tool_call_result(
          tool_calls,
          last_response,
          error,
          llm_call_params,
          max_retries,
          attempt
        )

      {:ok, %EmptyResult{}} ->
        retry_with_schema_validation(
          last_response,
          error,
          llm_call_params,
          max_retries,
          attempt + 1
        )

      {:error, _reason} ->
        retry_with_schema_validation(
          last_response,
          error,
          llm_call_params,
          max_retries,
          attempt + 1
        )
    end
  end

  @spec retry_handle_content_result(
          ContentResult.t(),
          String.t() | map(),
          ValidationError.t(),
          llm_call_params(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          :ok | {:error, String.t()}
  defp retry_handle_content_result(
         %ContentResult{stream: stream},
         last_response,
         error,
         llm_call_params,
         max_retries,
         attempt
       ) do
    %{
      on_event: on_event_fn,
      branch_id: branch_id,
      tool_usage_counts: tool_usage_counts,
      schema: schema
    } =
      llm_call_params

    case process_stream(stream, on_event_fn, tool_usage_counts, branch_id) do
      {true, new_full_text} ->
        case Validator.validate(new_full_text, schema) do
          {:ok, validated_map} ->
            on_event_fn.({:llm_end, branch_id, validated_map})
            :ok

          {:error, %ValidationError{} = new_error} ->
            retry_with_schema_validation(
              new_full_text,
              new_error,
              llm_call_params,
              max_retries,
              attempt + 1
            )
        end

      {false, _} ->
        retry_with_schema_validation(
          last_response,
          error,
          llm_call_params,
          max_retries,
          attempt + 1
        )
    end
  end

  @spec retry_handle_tool_call_result(
          list(),
          String.t() | map(),
          ValidationError.t(),
          llm_call_params(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          :ok | {:error, String.t()}
  defp retry_handle_tool_call_result(
         tool_calls,
         last_response,
         error,
         llm_call_params,
         max_retries,
         attempt
       ) do
    if structured_output_tool_call?(tool_calls) do
      retry_handle_structured_output(
        tool_calls,
        last_response,
        error,
        llm_call_params,
        max_retries,
        attempt
      )
    else
      retry_with_schema_validation(
        last_response,
        error,
        llm_call_params,
        max_retries,
        attempt + 1
      )
    end
  end

  @spec retry_handle_structured_output(
          list(),
          String.t() | map(),
          ValidationError.t(),
          llm_call_params(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          :ok | {:error, String.t()}
  defp retry_handle_structured_output(
         tool_calls,
         last_response,
         error,
         llm_call_params,
         max_retries,
         attempt
       ) do
    %{on_event: on_event_fn, branch_id: branch_id, schema: schema} = llm_call_params
    synthetic_name = Enforcer.structured_output_tool_name()

    case Enum.find(tool_calls, &ReqLLM.ToolCall.matches_name?(&1, synthetic_name)) do
      nil ->
        retry_with_schema_validation(
          last_response,
          error,
          llm_call_params,
          max_retries,
          attempt + 1
        )

      tool_call ->
        args = ReqLLM.ToolCall.args_map(tool_call) || %{}

        case Validator.check_schema(args, schema) do
          :ok ->
            on_event_fn.({:llm_end, branch_id, args})
            :ok

          {:error, %ValidationError{} = new_error} ->
            retry_with_schema_validation(
              Jason.encode!(args),
              new_error,
              llm_call_params,
              max_retries,
              attempt + 1
            )
        end
    end
  end

  defp build_retry_prompt(last_response, %ValidationError{validation_errors: errors}) do
    error_details = Enum.join(errors, "\n")

    "Your previous response was invalid. The response was:\n#{last_response}\n\nValidation errors:\n#{error_details}\n\nPlease respond again with valid JSON matching the schema."
  end

  # --- Helpers ---

  defp structured_output_tool_call?(tool_calls) when is_list(tool_calls) do
    synthetic_name = Enforcer.structured_output_tool_name()

    Enum.any?(tool_calls, &ReqLLM.ToolCall.matches_name?(&1, synthetic_name))
  end

  defp structured_output_tool_call?(_), do: false

  defp schema_max_retries(%{schema_max_retries: n}) when is_integer(n) and n >= 0, do: n
  defp schema_max_retries(_), do: @default_schema_max_retries
end
