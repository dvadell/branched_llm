defmodule BranchedLLM.StructuredOutput.Enforcer.ToolCoerce do
  @moduledoc """
  Anthropic structured output enforcement via tool-use coercion.

  A synthetic tool is defined whose sole parameter matches the user's schema.
  The model is instructed to call this tool, and the library extracts the tool
  call arguments as the structured response.

  The orchestrator recognises the reserved tool name `__structured_output__`
  and short-circuits execution, extracting the arguments directly instead of
  dispatching to the normal tool-call path.
  """

  @behaviour BranchedLLM.StructuredOutput.Enforcer

  alias BranchedLLM.StructuredOutput.Enforcer

  @impl true
  @doc """
  Adds the synthetic structured-output tool to the request's tools list
  and sets `tool_choice` to force its invocation.
  """
  def prepare_request(request, schema) do
    synthetic_tool = Enforcer.build_synthetic_tool(schema)

    tools = Map.get(request, :tools, [])
    updated_tools = tools ++ [synthetic_tool]

    request
    |> Map.put(:tools, updated_tools)
    |> Map.put(:tool_choice, %{
      "type" => "function",
      "function" => %{"name" => Enforcer.structured_output_tool_name()}
    })
  end

  @impl true
  @doc """
  Extracts the structured response from a tool call's arguments.

  For the Anthropic path, the response comes as a tool call with the
  reserved `__structured_output__` name. The arguments ARE the structured data.
  """
  def extract_response(%{tool_calls: tool_calls}, _schema) when is_list(tool_calls) do
    synthetic_name = Enforcer.structured_output_tool_name()

    case Enum.find(tool_calls, fn tc ->
           ReqLLM.ToolCall.name(tc) == synthetic_name
         end) do
      nil ->
        {:error, :structured_output_tool_not_found}

      tool_call ->
        {:ok, ReqLLM.ToolCall.args_map(tool_call) || %{}}
    end
  end

  def extract_response(%{text: text}, _schema) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:error, :invalid_json}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  def extract_response(_raw_response, _schema) do
    {:error, :unsupported_response_format}
  end
end
