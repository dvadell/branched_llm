defmodule BranchedLLM.Chat do
  @moduledoc """
  Frontend Chat API — convenience functions for callers.

  Provides synchronous message sending, context management, and health
  checks. For the LLM client that the orchestrator calls into, see
  `BranchedLLM.ChatClient`.

  ## Configuration

  All configuration is under `:branched_llm`:

      config :branched_llm,
        ai_model: System.get_env("LLM_MODEL") || "ollama:cara-cpu",
        base_url: System.get_env("LLM_BASE_URL") || "http://localhost:11434"
  """

  import ReqLLM.Context

  require Logger

  alias ReqLLM.Context

  @behaviour BranchedLLM.ChatBehaviour

  ## Delegations to ChatClient

  delegate_to = [default_model: 0, send_message_stream: 2, stream_text: 3, execute_tool: 3]

  for {name, arity} <- delegate_to do
    args = Macro.generate_arguments(arity, __MODULE__)

    @doc false
    def unquote(name)(unquote_splicing(args)) do
      apply(BranchedLLM.ChatClient, unquote(name), unquote(args))
    end
  end

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
        chat_mod: BranchedLLM.ChatClient,
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
      {^ref, :chunk, chunk} ->
        wait_for_sync_result(ref, acc <> chunk, context, nil)

      {^ref, :end, full_text} ->
        {:ok, full_text, add_assistant_message(context, full_text)}

      {^ref, :error, err} ->
        {:error, err}
    after
      60_000 -> {:error, "Timed out waiting for LLM response"}
    end
  end

  # When a schema is provided, :llm_end delivers a validated map instead of
  # raw text — return it directly without concatenating chunks.
  defp wait_for_sync_result(ref, _acc, context, _schema) do
    receive do
      {^ref, :end, validated_map} when is_map(validated_map) ->
        {:ok, validated_map, context}

      {^ref, :error, err} ->
        {:error, err}
    after
      60_000 -> {:error, "Timed out waiting for LLM response"}
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
  @impl true
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

  ## Private Functions

  defp build_config(opts) do
    %{
      model: Keyword.get(opts, :model, BranchedLLM.ChatClient.default_model()),
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

  if Code.ensure_loaded?(OpentelemetryReq) do
    defp maybe_attach_telemetry(req), do: OpentelemetryReq.attach(req, no_path_params: true)
  else
    defp maybe_attach_telemetry(req), do: req
  end
end
