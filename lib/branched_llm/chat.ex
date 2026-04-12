defmodule BranchedLLM.Chat do
  @moduledoc """
  Core chat functionality for interacting with LLM APIs.

  Handles message sending, streaming, and conversation context management.
  This is a default implementation of `BranchedLLM.ChatBehaviour` using `ReqLLM`.

  ## Configuration

      config :branched_llm,
        ai_model: "openai:gpt-4",
        base_url: "http://localhost:11434"

  Or configure via `:req_llm`:

      config :req_llm,
        openai: [base_url: "http://localhost:11434/api"]

  """
  import ReqLLM.Context

  require Logger

  alias BranchedLLM.LLM.StreamParser
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
  """
  @impl true
  @spec send_message(String.t(), Context.t(), keyword()) ::
          {:ok, String.t(), Context.t()} | {:error, term()}
  def send_message(message, context, opts \\ []) do
    config = build_config(opts)
    updated_context = add_user_message(context, message)

    case call_llm(config.model, updated_context, config.tools) do
      {:ok, stream_response, _tool_calls} ->
        final_text = StreamParser.consume_to_text(stream_response.stream)
        final_context = add_assistant_message(updated_context, final_text)
        {:ok, final_text, final_context}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Sends a message and returns a stream of text chunks plus the updated context,
  and any tool calls made by the LLM.
  Perfect for web interfaces that need to stream responses to users and handle tools.

  ## Examples

      iex> context = BranchedLLM.Chat.new_context("You are a helpful assistant")
      iex> {:ok, stream, context_builder, tool_calls} = BranchedLLM.Chat.send_message_stream("Hello!", context, tools: [some_tool()])
      iex> Enum.each(stream, fn chunk -> IO.write(chunk) end)

  ## Returns

    * `{:ok, stream, context_builder_fn, tool_calls}` - Stream of text chunks, a function to build final context, and a list of tool calls

  ## Options

    * `:model` - The model to use (defaults to the model specified in the application config).
    * `:tools` - A list of `ReqLLM.Tool` structs to provide to the LLM.
  """
  @impl true
  @spec send_message_stream(String.t(), Context.t(), keyword()) ::
          {:ok, ReqLLM.StreamResponse.t(), (String.t() -> Context.t()), list()} | {:error, term()}
  def send_message_stream(message, context, opts \\ []) do
    config = build_config(opts)

    updated_context =
      if message != nil and message != "" do
        add_user_message(context, message)
      else
        context
      end

    case call_llm(config.model, updated_context, config.tools) do
      {:ok, stream_response, tool_calls} ->
        context_builder = fn final_text -> add_assistant_message(updated_context, final_text) end
        {:ok, stream_response, context_builder, tool_calls}

      {:error, reason} ->
        {:error, reason}
    end
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
  Returns the default model string.
  """
  @spec default_model() :: String.t()
  def default_model do
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

  @spec add_assistant_message(Context.t(), String.t()) :: Context.t()
  defp add_assistant_message(context, message) do
    Context.append(context, assistant(message))
  end

  @spec call_llm(String.t(), Context.t(), list()) ::
          {:ok, StreamResponse.t(), list()} | {:error, term()}
  defp call_llm(model, context, tools) do
    do_call_llm(model, context, tools)
  end

  defp do_call_llm(model, context, tools) do
    Logger.info("LLM call_llm starting with context: #{inspect(context)}")
    start_time = :erlang.monotonic_time(:millisecond)

    %{model_endpoint: model_endpoint} = endpoints()

    result =
      case ReqLLM.stream_text(model, context.messages, tools: tools, base_url: model_endpoint) do
        {:ok, stream_response} ->
          stream_result(stream_response, tools)

        {:error, reason} ->
          {:error, reason}
      end

    end_time = :erlang.monotonic_time(:millisecond)

    Logger.info(
      "LLM call_llm(model: #{model}, tools: #{length(tools)}) took #{end_time - start_time}ms"
    )

    result
  end

  defp stream_result(stream_response, []), do: {:ok, stream_response, []}
  defp stream_result(stream_response, _tools), do: handle_stream_for_tools(stream_response)

  # Peeks at the stream to see if the LLM is calling a tool or just talking.
  defp handle_stream_for_tools(%StreamResponse{stream: stream} = stream_response) do
    # We take chunks until we see a tool call or content with text.
    case StreamParser.consume_until_intent(stream) do
      {:tool_call, consumed_chunks, remaining_stream} ->
        # It's a tool call! Consume the whole stream to get all arguments.
        all_chunks = consumed_chunks ++ Enum.to_list(remaining_stream)
        tool_calls = StreamParser.extract_tool_calls(all_chunks)

        # We need to provide a dummy stream because the original one is consumed
        {:ok, dummy_stream_response(stream_response), tool_calls}

      {:content, consumed_chunks, remaining_stream} ->
        # It's content (text). Prepend the chunks we took and return as a normal stream.
        new_stream = Stream.concat(consumed_chunks, remaining_stream)
        {:ok, %{stream_response | stream: new_stream}, []}

      {:empty, _consumed_chunks} ->
        # Empty stream
        {:ok, stream_response, []}
    end
  rescue
    e -> {:error, e}
  end

  defp dummy_stream_response(%StreamResponse{context: context, model: model}) do
    %StreamResponse{
      stream: [%ReqLLM.StreamChunk{type: :content, text: ""}],
      context: context,
      model: model,
      cancel: fn -> :ok end,
      metadata_task: Task.async(fn -> %{} end)
    }
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

  defp endpoints do
    # First check branched_llm config
    base_url = Application.get_env(:branched_llm, :base_url)

    config_url =
      if base_url do
        base_url
      else
        :req_llm
        |> Application.get_env(:openai, [])
        |> Keyword.get(:base_url)
      end

    uri = URI.parse(config_url)
    port_str = if uri.port, do: ":#{uri.port}", else: ""
    base_url = "#{uri.scheme}://#{uri.host}#{port_str}"

    %{
      base_url: base_url,
      model_endpoint: base_url <> "/v1",
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
