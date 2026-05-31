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
    accumulated text of the assistant's response. When a schema is provided, this is a
    validated Elixir map instead of raw text.
  * `{:llm_status, branch_id, status}` — A status update (e.g., "Thinking...", "Using calculator...")
  * `{:llm_error, branch_id, error_message}` — An error occurred during the LLM request.
  * `{:llm_metadata, branch_id, metadata}` — Token-usage and other metadata from the LLM provider.
  * `{:update_tool_usage_counts, counts}` — Updated tool usage counts for the caller to track

  The caller may also send messages back (e.g., to cancel a task), but those are handled
  externally via the `active_task` PID in `BranchedChat`.

  ## Schema vs Non-Schema

  When `schema:` is provided, the orchestrator routes through `SchemaStream.run/1`,
  which validates the response against the schema and retries on validation failure.
  Otherwise it routes through `CallbackStream.run/1`.
  """

  alias BranchedLLM.ChatOrchestrator.{CallbackStream, SchemaStream}
  alias BranchedLLM.LLMErrorFormatter

  use Retry

  @type llm_call_params :: %{
          required(:llm_context) => ReqLLM.Context.t(),
          required(:on_event) => function(),
          optional(:llm_tools) => list(),
          required(:chat_mod) => module(),
          optional(:tool_usage_counts) => map(),
          required(:branch_id) => String.t(),
          optional(:schema) => map() | nil,
          optional(:schema_max_retries) => non_neg_integer() | nil
        }

  @doc """
  Starts the LLM request process in a separate task.

  The task communicates with the caller via messages defined in the module doc.

  Routes to either `CallbackStream` or `SchemaStream` based on whether `:schema` is present.
  """
  @spec run(llm_call_params()) :: {:ok, pid()}
  def run(params) do
    Task.start(fn -> do_process(params) end)
  end

  defp do_process(%{schema: schema} = params) when not is_nil(schema) do
    case SchemaStream.run(params) do
      :ok -> :ok
      {:error, reason} -> params.on_event.({:llm_error, params.branch_id, reason})
    end
  rescue
    exception ->
      params.on_event.({:llm_error, params.branch_id, LLMErrorFormatter.format(exception)})
  end

  defp do_process(params) do
    result =
      retry with: constant_backoff(100) |> Stream.take(10) do
        case CallbackStream.run(params) do
          :ok ->
            :ok

          {:error, reason} ->
            params.on_event.({:llm_status, params.branch_id, "Retrying..."})
            {:error, reason}
        end
      end

    case result do
      :ok -> :ok
      {:error, reason} -> params.on_event.({:llm_error, params.branch_id, reason})
    end
  rescue
    exception ->
      params.on_event.({:llm_error, params.branch_id, LLMErrorFormatter.format(exception)})
  end

  def build_stream_opts(%{schema: schema} = params) when not is_nil(schema) do
    provider_options = schema_provider_options(schema)

    []
    |> Keyword.put(:tools, Map.get(params, :llm_tools, []))
    |> Keyword.put(:schema, schema)
    |> Keyword.put(:provider_options, provider_options)
  end

  def build_stream_opts(params) do
    Keyword.new([{:tools, Map.get(params, :llm_tools, [])}])
  end

  @doc false
  @spec schema_provider_options(map()) :: keyword()
  def schema_provider_options(schema) do
    case ReqLLM.Schema.compile(schema) do
      {:ok, compiled} ->
        json_schema = ReqLLM.Schema.to_json(compiled.schema)

        response_format = %{
          type: "json_schema",
          json_schema: %{
            name: "structured_output",
            schema: json_schema
          }
        }

        [response_format: response_format]

      {:error, _} ->
        []
    end
  end
end
