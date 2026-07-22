defmodule BranchedLLM.ChatClient do
  @moduledoc """
  The LLM client that `ChatOrchestrator` calls into.

  This module implements the `BranchedLLM.ChatClientBehaviour` — the contract
  between the orchestrator and the LLM backend. It provides streaming message
  dispatch, tool execution with caching, model resolution, and the low-level
  `stream_text/3` call to ReqLLM.

  The orchestrator references this module (or any module implementing
  `ChatClientBehaviour`) as `chat_mod` in its params map.

  ## Configuration

  All configuration is under `:branched_llm`:

      config :branched_llm,
        ai_model: System.get_env("LLM_MODEL") || "ollama:cara-cpu",
        base_url: System.get_env("LLM_BASE_URL") || "http://localhost:11434"
  """

  require Logger

  alias BranchedLLM.ContextManager
  alias BranchedLLM.LLM.StreamResult
  alias BranchedLLM.LLM.StreamResult.{ContentResult, EmptyResult, ErrorResult, ToolCallResult}

  alias ReqLLM.Context
  alias ReqLLM.StreamChunk
  alias ReqLLM.StreamResponse
  alias ReqLLM.ToolCall

  alias BranchedLLM.ProviderConfig

  @behaviour BranchedLLM.ChatClientBehaviour

  @doc """
  Sends a message stream and returns a `BranchedLLM.LLM.StreamResult` tagged union.

  The result is one of three structs that clearly distinguishes the LLM's intent:

    * `%ContentResult{}` — The LLM is streaming text content.
    * `%ToolCallResult{}` — The LLM is invoking one or more tools.
    * `%EmptyResult{}` — The LLM returned neither content nor tool calls.

  ## Options

    * `:model` - The model to use (defaults to the model specified in the application config).
    * `:tools` - A list of `ReqLLM.Tool` structs to provide to the LLM.
    * `:max_tokens` - Maximum context window tokens (overrides app config).
    * `:trim_callback` - Custom context trimming callback (overrides app config).
    * `:provider_options` - Provider-specific options forwarded to ReqLLM.
  """
  @impl true
  @spec send_message_stream(Context.t(), keyword()) :: {:ok, StreamResult.t()} | {:error, term()}
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
  Returns the default model, resolved to a `%LLMDB.Model{}` struct.

  Reads from :branched_llm config, then falls back to a default.
  Resolving the model string through `ReqLLM.model/1` once avoids
  repeated "unverified model" warnings on every LLM call.
  """
  @spec default_model() :: ReqLLM.model_input()
  @impl true
  def default_model do
    model_string =
      Application.get_env(:cara, :ai_model) ||
        Application.get_env(:branched_llm, :ai_model, "ollama:cara-cpu")

    resolve_model(model_string)
  end

  @doc """
  Calls the LLM provider to stream text for the given context.

  ## Options

    * `:tools` - List of `ReqLLM.Tool` structs.
    * `:base_url` - Override the configured base URL.
    * `:provider_options` - Provider-specific options forwarded to ReqLLM.
  """
  @impl true
  @spec stream_text(ReqLLM.model_input(), Context.t(), keyword()) ::
          {:ok, StreamResponse.t()} | {:error, term()}
  def stream_text(model, context, opts) do
    provider = ProviderConfig.resolve_provider(model)
    %{model_endpoint: model_endpoint} = ProviderConfig.endpoints(provider)
    model_endpoint = Keyword.get(opts, :base_url, model_endpoint)
    api_key = Keyword.get(opts, :api_key) || ProviderConfig.api_key(provider)
    tools = Keyword.get(opts, :tools, [])
    provider_options = Keyword.get(opts, :provider_options, [])

    base_opts = [tools: tools, base_url: model_endpoint, api_key: api_key]

    stream_opts =
      if provider_options != [],
        do: Keyword.put(base_opts, :provider_options, provider_options),
        else: base_opts

    stream_opts = maybe_put_on_finch_request(stream_opts)

    resolved_model = resolve_model(model)

    ReqLLM.stream_text(resolved_model, context.messages, stream_opts)
  end

  @doc """
  Executes a given tool with the provided arguments.

  Uses a caching layer to retrieve previous successful results.
  The cache module can be configured via:

      config :branched_llm, tool_cache: MyApp.ToolCache

  Or passed directly via opts:

      BranchedLLM.ChatClient.execute_tool(tool, args, cache: MyApp.ToolCache)
  """
  @impl true
  @spec execute_tool(ReqLLM.Tool.t(), map()) :: {:ok, term()} | {:error, term()}
  def execute_tool(tool, args, opts \\ []) do
    cache_module = Keyword.get(opts, :cache, default_tool_cache())

    maybe_with_span("tool_execution", %{tool: tool.name}, fn ->
      do_execute_tool(tool, args, cache_module)
    end)
  end

  ## Private Functions

  defp build_config(opts) do
    %{
      model: Keyword.get(opts, :model, default_model()),
      tools: Keyword.get(opts, :tools, [])
    }
  end

  defp context_trim_opts(opts) do
    Keyword.take(opts, [:max_tokens, :trim_callback])
  end

  @spec call_llm(ReqLLM.model_input(), Context.t(), list(), keyword()) ::
          {:ok, StreamResult.t()} | {:error, term()}
  defp call_llm(model, context, tools, opts) do
    stream_opts =
      [tools: tools]
      |> maybe_put_provider_options(opts)

    result =
      case stream_text(model, context, stream_opts) do
        {:ok, stream_response} -> {:ok, stream_result(stream_response, tools)}
        {:error, reason} -> {:error, reason}
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

  # Resolves a "provider:model_id" string into a ReqLLM model map
  # to suppress the "unverified model" warning from ReqLLM.model/1.
  @spec resolve_model(ReqLLM.model_input()) :: ReqLLM.model_input()
  defp resolve_model(model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [provider_str, model_id] when provider_str != "" ->
        try do
          provider = String.to_existing_atom(provider_str)
          %{provider: provider, id: model_id}
        rescue
          ArgumentError -> model
        end

      _ ->
        model
    end
  end

  defp resolve_model(model), do: model

  # When no tools are provided, the stream is always content — no intent detection needed.
  @spec stream_result(StreamResponse.t(), list()) :: StreamResult.t()
  defp stream_result(stream_response, []), do: %ContentResult{stream: stream_response}

  # When tools are provided, classify the stream to determine intent.
  defp stream_result(stream_response, _tools), do: handle_stream_for_tools(stream_response)

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

  defp map_to_tool_call(%{id: id, name: name, arguments: args}) do
    args_json = if is_map(args), do: Jason.encode!(args), else: args || "{}"
    ToolCall.new(id, name, args_json)
  end

  defp do_execute_tool(tool, args, cache_module) do
    case cache_module.get_result(tool.name, args) do
      {:ok, result} ->
        Logger.info("Tool '#{tool.name}' result retrieved from cache.")

        :telemetry.execute(
          [:branched_llm, :ai, :tool, :cache, :hit],
          %{count: 1},
          %{tool: tool.name}
        )

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

  defp maybe_put_on_finch_request(opts) do
    case Application.get_env(:branched_llm, :on_request) do
      nil -> opts
      fun -> Keyword.put(opts, :on_finch_request, fun)
    end
  end

  # OpenTelemetry helpers
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
end
