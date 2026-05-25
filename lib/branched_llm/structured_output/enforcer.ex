defmodule BranchedLLM.StructuredOutput.Enforcer do
  @moduledoc """
  Behaviour and dispatcher for provider-specific structured output enforcement.

  Each provider implements `prepare_request/2` (to modify the outgoing API call)
  and `extract_response/2` (to extract the structured payload from the raw response).

  The dispatcher selects the correct enforcer based on the provider atom resolved
  from the model string.
  """

  @callback prepare_request(request :: map(), schema :: map()) :: map()
  @callback extract_response(raw_response :: map(), schema :: map()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Resolves the provider atom from a model spec (string or `%LLMDB.Model{}`).

  Strings like `"openai:gpt-4"` are split on `:` to extract the provider.
  `%LLMDB.Model{}` structs use the `:provider` field directly.
  """
  @spec resolve_provider(ReqLLM.model_input()) :: atom()
  def resolve_provider(%LLMDB.Model{provider: provider}) when is_atom(provider) do
    case ReqLLM.provider(provider) do
      {:ok, _} -> provider
      {:error, _} -> :unknown
    end
  end

  def resolve_provider(model_string) when is_binary(model_string) do
    case String.split(model_string, ":", parts: 2) do
      [provider_str, _model_id] ->
        try do
          provider = String.to_existing_atom(provider_str)

          case ReqLLM.provider(provider) do
            {:ok, _} -> provider
            {:error, _} -> :unknown
          end
        rescue
          ArgumentError -> :unknown
        end

      _ ->
        :unknown
    end
  end

  def resolve_provider(_), do: :unknown

  @doc """
  Dispatches `prepare_request/2` to the appropriate enforcer module.
  """
  @spec prepare_request(atom(), map(), map()) :: map()
  def prepare_request(provider, request, schema) do
    enforcer = enforcer_for(provider)
    enforcer.prepare_request(request, schema)
  end

  @doc """
  Dispatches `extract_response/2` to the appropriate enforcer module.
  """
  @spec extract_response(atom(), map(), map()) :: {:ok, map()} | {:error, term()}
  def extract_response(provider, raw_response, schema) do
    enforcer = enforcer_for(provider)
    enforcer.extract_response(raw_response, schema)
  end

  @doc """
  Returns the enforcer module for a given provider atom.
  """
  @spec enforcer_for(atom()) :: module()
  def enforcer_for(:openai), do: BranchedLLM.StructuredOutput.Enforcer.JsonSchema
  def enforcer_for(:anthropic), do: BranchedLLM.StructuredOutput.Enforcer.ToolCoerce
  def enforcer_for(:ollama), do: BranchedLLM.StructuredOutput.Enforcer.Grammar
  def enforcer_for(:llamacpp), do: BranchedLLM.StructuredOutput.Enforcer.Grammar
  def enforcer_for(:vllm), do: BranchedLLM.StructuredOutput.Enforcer.Prompt
  def enforcer_for(_), do: BranchedLLM.StructuredOutput.Enforcer.Prompt

  @doc """
  Reserved tool name used for Anthropic tool-coercion.
  The orchestrator recognises this name and short-circuits execution.
  """
  @spec structured_output_tool_name() :: String.t()
  def structured_output_tool_name, do: "__structured_output__"

  @doc """
  Builds the synthetic tool definition for Anthropic tool-coercion.
  """
  @spec build_synthetic_tool(map()) :: map()
  def build_synthetic_tool(schema) do
    %{
      "type" => "function",
      "function" => %{
        "name" => structured_output_tool_name(),
        "description" => "Respond with structured data matching the provided schema.",
        "parameters" => schema
      }
    }
  end
end
