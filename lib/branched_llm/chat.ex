defmodule BranchedLLM.Chat do
  @moduledoc """
  Core chat functionality for interacting with LLM APIs.

  Handles message sending, streaming, and conversation context management.
  This is a default implementation of `BranchedLLM.ChatBehaviour` using `ReqLLM`.

  ## Configuration

      config :branched_llm, ai_model: "openai:gpt-4", base_url: "http://localhost:11434"

  Or configure via `:req_llm`:

      config :req_llm, openai: [base_url: "http://localhost:11434/api"]
  """

  import ReqLLM.Context
  require Logger

  alias BranchedLLM.LLM.StreamParser
  alias BranchedLLM.LLM.StreamResult
  alias BranchedLLM.LLM.StreamResult.{ContentResult, EmptyResult, ErrorResult, ToolCallResult}

  alias ReqLLM.Context
  alias ReqLLM.StreamResponse

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
  """
  @impl true
  @spec send_message(String.t(), Context.t(), keyword()) ::
          {:ok, String.t(), Context.t()} | {:error, term()}
  def send_message(message, context, opts \\ []) do
    config = build_config(opts)
    parent = self()
    ref = make_ref()

    on_event = fn
      {:llm_chunk, _id, chunk} -> send(parent, {ref, :chunk, chunk})
      {:llm_end, _id, builder} -> send(parent, {ref, :end, builder})
      {:llm_error, _id, err} -> send(parent, {ref, :error, err})
      _ -> :ok
    end

    params = %{
      message: message,
      llm_context: context,
      on_event: on_event,
      llm_tools: config.tools,
      chat_mod: __MODULE__,
      tool_usage_counts: %{},
      branch_id: "sync-call"
    }

    {:ok, _pid} = BranchedLLM.ChatOrchestrator.run(params)
    wait_for_sync_result(ref, "")
  end

  defp wait_for_sync_result(ref, acc) do
    receive do
      {^ref, :chunk, chunk} -> wait_for_sync_result(ref, acc <> chunk)
      {^ref, :end, builder} -> {:ok, acc, builder.(acc)}
      {^ref, :error, err} -> {:error, err}
    after
      60_000 -> {:error, "Timed out waiting for LLM response"}
    end
  end

  @doc """
  Sends a message and returns a `BranchedLLM.LLM.StreamResult` tagged union.

  The result is one of three structs that clearly distinguishes the LLM's intent:

    * `%ContentResult{}` — The LLM is streaming text content.
    * `%ToolCallResult{}` — The LLM is invoking one or more tools.
    * `%EmptyResult{}` — The LLM returned neither content nor tool calls.

  ## Examples

      iex> context = BranchedLLM.Chat.new_context("You are a helpful assistant")
      iex> {:ok, %ContentResult{} = result} = BranchedLLM.Chat.send_message_stream("Hello!", context)
      iex> Enum.each(result.stream, fn chunk -> IO.write(chunk) end)

  ## Options

    * `:model` - The model to use (defaults to the model specified in the application config).
    * `:tools` - A list of `ReqLLM.Tool` structs to provide to the LLM.
  """
  @impl true
  @spec send_message_stream(String.t(), Context.t(), keyword()) ::
          {:ok, StreamResult.t()} | {:error, term()}
  def send_message_stream(message, context, opts \\ []) do
    config = build_config(opts)

    updated_context =
      if message != "" do
        add_user_message(context, message)
      else
        context
      end

    context_builder = fn final_text ->
      add_assistant_message(updated_context, final_text)
    end

    call_llm(config.model, updated_context, config.tools)
    |> unwrap_call_llm_result(context_builder)
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
      iex> length(history) 1
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
  Returns the default model string.
  Reads from :req_llm config first, falls back to :branched_llm, then to a default.
  """
  @spec default_model() :: String.t()
  def default_model do
    Application.get_env(:req_llm, :model) ||
      Application.get_env(:branched_llm, :ai_model, "openai:cara-cpu")
  end

  ## Private Functions

  defp build_config(opts) do
    %{
      model: Keyword.get(opts, :model, default_model()),
      tools: Keyword.get(opts, :tools, [])
    }
  end

  @spec add_user_message(Context.t(), String.t()) :: Context.t()
  defp add_user_message(context, message) do
    Context.append(context, user(message))
  end

  @spec add_assistant_message(Context.t(), String.t(), keyword()) :: Context.t()
  defp add_assistant_message(context, message, opts \\ []) do
    Context.append(context, assistant(message, opts))
  end

  @spec call_llm(String.t(), Context.t(), list()) :: StreamResult.t()
  defp call_llm(model, context, tools) do
    Logger.info("LLM call_llm starting with context: #{inspect(context)}")
    start_time = :erlang.monotonic_time(:millisecond)

    result =
      case __MODULE__.stream_text(model, context, tools: tools) do
        {:ok, stream_response} -> stream_result(stream_response, tools)
        {:error, reason} -> %ErrorResult{reason: reason}
      end

    end_time = :erlang.monotonic_time(:millisecond)

    Logger.info(
      "LLM call_llm(model: #{model}, tools: #{length(tools)}) took #{end_time - start_time}ms"
    )

    result
  end

  @doc false
  @impl true
  @spec stream_text(String.t(), Context.t(), keyword()) ::
          {:ok, StreamResponse.t()} | {:error, term()}
  def stream_text(model, context, opts) do
    model_endpoint = Keyword.get(opts, :base_url, endpoints().model_endpoint)
    tools = Keyword.get(opts, :tools, [])
    ReqLLM.stream_text(model, context.messages, tools: tools, base_url: model_endpoint)
  end

  @spec unwrap_call_llm_result(StreamResult.t(), (String.t() -> Context.t())) ::
          {:ok, StreamResult.t()} | {:error, term()}
  defp unwrap_call_llm_result(%ErrorResult{reason: reason}, _context_builder) do
    {:error, reason}
  end

  defp unwrap_call_llm_result(result, context_builder) do
    {:ok, inject_context_builder(result, context_builder)}
  end

  @spec inject_context_builder(StreamResult.t(), (String.t() -> Context.t())) :: StreamResult.t()
  defp inject_context_builder(%ContentResult{} = result, context_builder) do
    %{result | context_builder: context_builder}
  end

  defp inject_context_builder(%ToolCallResult{} = result, context_builder) do
    %{result | context_builder: context_builder}
  end

  defp inject_context_builder(%EmptyResult{} = result, context_builder) do
    %{result | context_builder: context_builder}
  end

  # When no tools are provided, the stream is always content — no intent detection needed.
  @spec stream_result(StreamResponse.t(), list()) :: {:ok, StreamResult.t()} | {:error, term()}
  defp stream_result(stream_response, []),
    do: {:ok, %ContentResult{stream: stream_response, context_builder: nil}}

  # When tools are provided, peek at the stream to determine intent.
  defp stream_result(stream_response, _tools), do: handle_stream_for_tools(stream_response)

  # Peeks at the stream to see if the LLM is calling a tool or just talking.
  # Returns a tagged StreamResult struct instead of the old 3-tuple + dummy stream.
  defp handle_stream_for_tools(%StreamResponse{stream: stream} = stream_response) do
    case StreamParser.consume_until_intent(stream) do
      {:tool_call, consumed_chunks, remaining_stream} ->
        # It's a tool call! Consume the whole stream to get all arguments.
        all_chunks = consumed_chunks ++ Enum.to_list(remaining_stream)
        tool_calls = StreamParser.extract_tool_calls(all_chunks)

        {:ok,
         %ToolCallResult{
           tool_calls: tool_calls,
           context: stream_response.context,
           context_builder: nil
         }}

      {:content, consumed_chunks, remaining_stream} ->
        # It's content (text). Prepend the chunks we took and return as a normal stream.
        new_stream = Stream.concat(consumed_chunks, remaining_stream)

        {:ok,
         %ContentResult{stream: %{stream_response | stream: new_stream}, context_builder: nil}}

      {:empty, _consumed_chunks} ->
        # Empty stream — explicit empty result, no dummy stream.
        {:ok, %EmptyResult{context_builder: nil}}
    end
  rescue
    e in Jason.EncodeError -> {:error, e}
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

  @doc """
  Checks if the configured LLM provider is available.
  """
  @impl true
  def health_check do
    %{health_endpoint: health_endpoint} = endpoints()
    Logger.info("Checking AI health at: #{health_endpoint}")

    case Req.new(
           connect_options: [timeout: 1000],
           retry: false
         )
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
    # Read base_url from :req_llm openai config (single source of truth)
    # Falls back to :branched_llm base_url for backward compatibility
    config_url =
      :req_llm
      |> Application.get_env(:openai, [])
      |> Keyword.get(:base_url) ||
        Application.get_env(:branched_llm, :base_url) ||
        "http://localhost:11434"

    # If the config URL already includes /v1, use it as-is for model_endpoint.
    # Otherwise append /v1 (backward compat with Ollama-style base URLs).
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
