defmodule BranchedLLM.Chat do
  @moduledoc """
  Core chat functionality for interacting with LLM APIs.

  Handles message sending, streaming, and conversation context management.

  This is a default implementation of `BranchedLLM.ChatBehaviour` using `ReqLLM`.

  ## Configuration

  All configuration is under `:branched_llm` and can be set via environment variables:

      config :branched_llm,
        ai_model: System.get_env("LLM_MODEL") || "ollama:cara-cpu",
        base_url: System.get_env("LLM_BASE_URL") || "http://localhost:11434"
  """

  import ReqLLM.Context

  require Logger

  alias BranchedLLM.ContextManager
  alias BranchedLLM.LLM.StreamResult
  alias BranchedLLM.LLM.StreamResult.{ContentResult, EmptyResult, ErrorResult, ToolCallResult}

  alias ReqLLM.Context
  alias ReqLLM.StreamChunk
  alias ReqLLM.StreamResponse
  alias ReqLLM.ToolCall

  @behaviour BranchedLLM.ChatBehaviour

  @type stream_chunk :: %{type: atom(), text: String.t()}

  ## Public API

  @doc """
  Sends a single message and returns the response without entering a loop.
  Uses streaming internally but returns the complete text.

  ## Examples

      iex> context = BranchedLLM.Chat.new_context("You are a helpful assistant")
      iex> {:ok, response, new_context} = BranchedLLM.Chat.send_message("Hello!", context)

  ## Options

    * `:model` - The model to use (defaults to the model specified in the application config).
    * `:tools` - A list of `ReqLLM.Tool` structs to provide to the LLM.
    * `:schema` - A JSON Schema map; when provided, the response is a validated map instead of raw text.
    * `:schema_max_retries` - Maximum retries on schema validation failure (default: 2).
  """
  @impl true
  @spec send_message(String.t(), Context.t(), keyword()) ::
          {:ok, String.t() | map(), Context.t()} | {:error, term()}
  def send_message(message, context, opts \\ []) do
    config = build_config(opts)

    parent = self()
    ref = make_ref()
    schema = Keyword.get(opts, :schema)

    on_event = fn
      {:llm_chunk, _id, chunk} -> send(parent, {ref, :chunk, chunk})
      {:llm_end, _id, payload} -> send(parent, {ref, :end, payload})
      {:llm_error, _id, err} -> send(parent, {ref, :error, err})
      _ -> :ok
    end

    updated_context = add_user_message(context, message)

    params =
      %{
        llm_context: updated_context,
        on_event: on_event,
        llm_tools: config.tools,
        chat_mod: __MODULE__,
        tool_usage_counts: %{},
        branch_id: "sync-call"
      }
      |> maybe_put_schema_param(opts)
      |> maybe_put_schema_max_retries_param(opts)

    {:ok, _pid} = BranchedLLM.ChatOrchestrator.run(params)

    wait_for_sync_result(ref, "", updated_context, schema)
  end

  defp wait_for_sync_result(ref, acc, context, nil) do
    receive do
      {^ref, :chunk, chunk} -> wait_for_sync_result(ref, acc <> chunk, context, nil)
      {^ref, :end, full_text} -> {:ok, full_text, add_assistant_message(context, full_text)}
      {^ref, :error, err} -> {:error, err}
    after
      60_000 -> {:error, "Timed out waiting for LLM response"}
    end
  end

  # When a schema is provided, :llm_end delivers a validated map instead of
  # raw text — return it directly without concatenating chunks.
  defp wait_for_sync_result(ref, _acc, context, _schema) do
    receive do
      {^ref, :end, validated_map} when is_map(validated_map) -> {:ok, validated_map, context}
      {^ref, :error, err} -> {:error, err}
    after
      60_000 -> {:error, "Timed out waiting for LLM response"}
    end
  end

  @doc """
  Sends a message stream and returns a `BranchedLLM.LLM.StreamResult` tagged union.

  The result is one of three structs that clearly distinguishes the LLM's intent:

    * `%ContentResult{}` — The LLM is streaming text content.
    * `%ToolCallResult{}` — The LLM is invoking one or more tools.
    * `%EmptyResult{}` — The LLM returned neither content nor tool calls.

  ## Examples

      iex> context = BranchedLLM.Chat.new_context("You are a helpful assistant")
      iex> context_with_msg = ReqLLM.Context.append(context, ReqLLM.Context.user("Hello!"))
      iex> %ContentResult{} = result} = BranchedLLM.Chat.send_message_stream(context_with_msg)
      iex> Enum.each(result.stream, fn chunk -> IO.write(chunk) end)

  ## Options

    * `:model` - The model to use (defaults to the model specified in the application config).
    * `:tools` - A list of `ReqLLM.Tool` structs to provide to the LLM.
    * `:max_tokens` - Maximum context window tokens (overrides app config). See `BranchedLLM.ContextManager`.
    * `:trim_callback` - Custom context trimming callback (overrides app config). See `BranchedLLM.ContextManager`.
  """
  @impl true
  @spec send_message_stream(Context.t(), keyword()) ::
          {:ok, StreamResult.t()} | {:error, term()}
  def send_message_stream(context, opts \\ []) do
    config = build_config(opts)
    provider_options = Keyword.get(opts, :provider_options)

    call_opts =
      []
      |> maybe_put_provider_options_from_opts(provider_options)

    {trimmed_context, was_trimmed} = ContextManager.trim(context, context_trim_opts(opts))

    if was_trimmed do
      Logger.info(
        "Context trimmed from #{length(context.messages)} to #{length(trimmed_context.messages)} messages"
      )
    end

    call_llm(config.model, trimmed_context, config.tools, call_opts)
  end

  @doc """
  Creates a new chat context with an optional custom system prompt.

  ## Examples

      iex> context = BranchedLLM.Chat.new_context("You are a helpful coding assistant")
  """
  @impl true
  @spec new_context(String.t()) :: Context.t()
  def new_context(system_prompt) do
    Context.new([system(system_prompt)])
  end

  @doc """
  Returns the conversation history as a list of messages.

  ## Examples

      iex> context = BranchedLLM.Chat.new_context()
      iex> history = BranchedLLM.Chat.get_history(context)
      iex> length(history)
      1
  """
  @spec get_history(Context.t()) :: list()
  def get_history(context) do
    context.messages
  end

  @doc """
  Clears the conversation history while keeping the system prompt.

  ## Examples

      iex> context = BranchedLLM.Chat.new_context()
      iex> context = BranchedLLM.Chat.reset_context(context)
  """
  @impl true
  @spec reset_context(Context.t()) :: Context.t()
  def reset_context(context) do
    system_messages = Enum.filter(context.messages, fn msg -> msg.role == :system end)
    Context.new(system_messages)
  end

  @doc """
  Returns the default model, resolved to a `%LLMDB.Model{}` struct.

  Reads from :branched_llm config, then falls back to a default.
  Resolving the model string through `ReqLLM.model/1` once avoids repeated
  "unverified model" warnings on every LLM call.
  """
  @spec default_model() :: ReqLLM.model_input()
  @impl true
  def default_model do
    model_string = Application.get_env(:branched_llm, :ai_model, "ollama:cara-cpu")

    case resolve_model(model_string) do
      {:ok, model} -> model
      {:error, _} -> model_string
    end
  end

  # Resolves a "provider:model_id" string into a %LLMDB.Model{} without
  # triggering the "unverified model" warning from ReqLLM.model/1.
  # Falls back to ReqLLM.model/1 for known-catalog models.
  @spec resolve_model(String.t()) :: {:ok, LLMDB.Model.t()} | {:error, term()}
  defp resolve_model(model_string) do
    case String.split(model_string, ":", parts: 2) do
      [provider_str, model_id] ->
        try do
          provider = String.to_existing_atom(provider_str)
          ReqLLM.model(%{provider: provider, id: model_id})
        rescue
          ArgumentError -> ReqLLM.model(model_string)
        end

      _ ->
        ReqLLM.model(model_string)
    end
  end

  ## Private Functions

  defp build_config(opts) do
    %{
      model: Keyword.get(opts, :model, default_model()),
      tools: Keyword.get(opts, :tools, [])
    }
  end

  # Extracts ContextManager options from the call opts keyword list.
  defp context_trim_opts(opts) do
    Keyword.take(opts, [:max_tokens, :trim_callback])
  end

  @spec add_user_message(Context.t(), String.t()) :: Context.t()
  defp add_user_message(context, message) do
    Context.append(context, user(message))
  end

  @spec add_assistant_message(Context.t(), String.t(), keyword()) :: Context.t()
  defp add_assistant_message(context, message, opts \\ []) do
    Context.append(context, assistant(message, opts))
  end

  @spec call_llm(ReqLLM.model_input(), Context.t(), list(), keyword()) ::
          {:ok, StreamResult.t()} | {:error, term()}
  defp call_llm(model, context, tools, opts) do
    stream_opts =
      [tools: tools]
      |> maybe_put_provider_options(opts)

    result =
      case __MODULE__.stream_text(model, context, stream_opts) do
        {:ok, stream_response} ->
          {:ok, stream_result(stream_response, tools)}

        {:error, reason} ->
          {:error, reason}
      end

    result
  end

  defp maybe_put_provider_options(stream_opts, opts) do
    case Keyword.get(opts, :provider_options) do
      nil -> stream_opts
      po -> Keyword.put(stream_opts, :provider_options, po)
    end
  end

  defp maybe_put_provider_options_from_opts(opts, nil), do: opts

  defp maybe_put_provider_options_from_opts(opts, po),
    do: Keyword.put(opts, :provider_options, po)

  defp maybe_put_schema_param(params, opts) do
    case Keyword.get(opts, :schema) do
      nil -> params
      schema -> Map.put(params, :schema, schema)
    end
  end

  defp maybe_put_schema_max_retries_param(params, opts) do
    case Keyword.get(opts, :schema_max_retries) do
      nil -> params
      n -> Map.put(params, :schema_max_retries, n)
    end
  end

  @doc false
  @impl true
  @spec stream_text(ReqLLM.model_input(), Context.t(), keyword()) ::
          {:ok, StreamResponse.t()} | {:error, term()}
  def stream_text(model, context, opts) do
    %{model_endpoint: model_endpoint} = endpoints()
    model_endpoint = Keyword.get(opts, :base_url, model_endpoint)
    tools = Keyword.get(opts, :tools, [])
    provider_options = Keyword.get(opts, :provider_options, [])

    base_opts = [tools: tools, base_url: model_endpoint]

    stream_opts =
      if provider_options != [] do
        Keyword.put(base_opts, :provider_options, provider_options)
      else
        base_opts
      end

    ReqLLM.stream_text(model, context.messages, stream_opts)
  end

  # When no tools are provided, the stream is always content — no intent detection needed.
  @spec stream_result(StreamResponse.t(), list()) :: StreamResult.t()
  defp stream_result(stream_response, []), do: %ContentResult{stream: stream_response}

  # When tools are provided, classify the stream to determine intent.
  defp stream_result(stream_response, _tools), do: handle_stream_for_tools(stream_response)

  # Consumes the full stream via classify/1 (which calls Enum.to_list
  # internally, keeping the StreamServer GenServer alive throughout).
  # Returns a tagged StreamResult struct based on the LLM's intent.
  defp handle_stream_for_tools(%StreamResponse{} = stream_response) do
    case StreamResponse.classify(stream_response) do
      %{type: :tool_calls, tool_calls: tool_call_maps} ->
        tool_calls = Enum.map(tool_call_maps, &map_to_tool_call/1)

        %ToolCallResult{
          tool_calls: tool_calls,
          context: stream_response.context,
          metadata_handle: stream_response.metadata_handle
        }

      %{type: :final_answer, text: text} when is_binary(text) and text != "" ->
        chunk = StreamChunk.text(text)
        new_stream = [chunk]
        %ContentResult{stream: %{stream_response | stream: new_stream}}

      _ ->
        %EmptyResult{}
    end
  rescue
    e in Jason.EncodeError -> %ErrorResult{reason: e}
  end

  # Converts a plain map (from StreamResponse.classify/1) back into a ToolCall struct.
  defp map_to_tool_call(%{id: id, name: name, arguments: args}) do
    args_json = if is_map(args), do: Jason.encode!(args), else: args || "{}"
    ToolCall.new(id, name, args_json)
  end

  @doc """
  Executes a given tool with the provided arguments.

  Uses a caching layer to retrieve previous successful results.
  The cache module can be configured via:

      config :branched_llm, tool_cache: MyApp.ToolCache

  Or passed directly via opts:

      BranchedLLM.Chat.execute_tool(tool, args, cache: MyApp.ToolCache)
  """
  @impl true
  @spec execute_tool(ReqLLM.Tool.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def execute_tool(tool, args, opts \\ []) do
    cache_module = Keyword.get(opts, :cache, default_tool_cache())

    maybe_with_span("tool_execution", %{tool: tool.name}, fn ->
      do_execute_tool(tool, args, cache_module)
    end)
  end

  defp do_execute_tool(tool, args, cache_module) do
    case cache_module.get_result(tool.name, args) do
      {:ok, result} ->
        Logger.info("Tool '#{tool.name}' result retrieved from cache.")

        :telemetry.execute([:branched_llm, :ai, :tool, :cache, :hit], %{count: 1}, %{
          tool: tool.name
        })

        {:ok, result}

      :error ->
        execute_and_cache(tool, args, cache_module)
    end
  end

  defp execute_and_cache(tool, args, cache_module) do
    case ReqLLM.Tool.execute(tool, args) do
      {:ok, result} = success ->
        cache_module.save_result(tool.name, args, result)
        success

      error ->
        error
    end
  end

  defp default_tool_cache do
    Application.get_env(:branched_llm, :tool_cache, BranchedLLM.ToolCache)
  end

  @doc """
  Checks if the configured LLM provider is available.
  """
  @impl true
  def health_check do
    %{health_endpoint: health_endpoint} = endpoints()
    Logger.info("Checking AI health at: #{health_endpoint}")

    case Req.new(connect_options: [timeout: 1000], retry: false)
         |> maybe_attach_telemetry()
         |> Req.get(url: health_endpoint) do
      {:ok, %{status: 200}} ->
        Logger.info("AI health check successful")
        :ok

      {:ok, %{status: status}} ->
        Logger.info("AI health check failed with status: #{status}")
        {:error, :unavailable}

      {:error, reason} ->
        Logger.info("AI health check failed with error: #{inspect(reason)}")
        {:error, :unavailable}
    end
  end

  @spec endpoints() :: %{
          base_url: String.t(),
          model_endpoint: String.t(),
          health_endpoint: String.t()
        }
  defp endpoints do
    config_url = Application.get_env(:branched_llm, :base_url) || "http://localhost:11434"

    uri = URI.parse(config_url)
    host = uri.host || "localhost"
    scheme = uri.scheme || "http"
    port_str = if uri.port, do: ":#{uri.port}", else: ""
    base_url = "#{scheme}://#{host}#{port_str}"

    model_endpoint =
      if String.ends_with?(config_url, "/v1") do
        config_url
      else
        base_url <> "/v1"
      end

    %{
      base_url: base_url,
      model_endpoint: model_endpoint,
      health_endpoint: base_url <> "/api/tags"
    }
  end

  # OpenTelemetry helpers
  # Compile-time branching: when :otel_tracer is loaded, spans are created.
  if Code.ensure_loaded?(OpenTelemetry.Tracer) do
    require OpenTelemetry.Tracer

    defp maybe_with_span(name, _attrs, fun) do
      OpenTelemetry.Tracer.with_span name do
        fun.()
      end
    end
  else
    defp maybe_with_span(_name, _attrs, fun), do: fun.()
  end

  if Code.ensure_loaded?(OpentelemetryReq) do
    defp maybe_attach_telemetry(req), do: OpentelemetryReq.attach(req, no_path_params: true)
  else
    defp maybe_attach_telemetry(req), do: req
  end
end
