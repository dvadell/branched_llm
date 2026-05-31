defmodule BranchedLLM.ToolHandler do
  @moduledoc """
  Handles tool execution and context management.

  This module contains pure functions for processing tool calls and managing the
  context updates.

  ## Example

      tool_call = ReqLLM.ToolCall.new("call_1", "calculator", %{"expression" => "2+2"})
      context = ReqLLM.Context.new([])
      tools = [CalculatorTool.calculator()]
      BranchedLLM.ToolHandler.handle_tool_calls([tool_call], context, tools, MyChatModule)
  """

  alias ReqLLM.Context
  alias ReqLLM.ToolCall
  require Logger

  @tool_usage_limit 10

  @doc """
  Processes tool calls, emits events, enforces usage limits, and returns
  updated orchestrator params map with the new context and tool_usage_counts.

  This consolidates the tool-call-handling logic that was previously duplicated
  between `WithSchema` and `NoSchema`.
  """
  @spec update_params_with_tool_results([ToolCall.t()], map()) :: map()
  def update_params_with_tool_results(tool_calls, params) do
    %{
      llm_context: llm_context,
      chat_mod: chat_mod,
      on_event: on_event_fn,
      branch_id: branch_id
    } = params

    llm_tools = Map.get(params, :llm_tools, [])
    tool_usage_counts = Map.get(params, :tool_usage_counts, %{})

    Enum.each(tool_calls, fn tool_call ->
      on_event_fn.(
        {:llm_tool_called, branch_id,
         %{
           id: tool_call.id,
           name: ToolCall.name(tool_call),
           arguments: tool_call.function.arguments
         }}
      )
    end)

    tool_names = Enum.map_join(tool_calls, ", ", &ToolCall.name/1)
    on_event_fn.({:llm_status, branch_id, "Using #{tool_names}..."})

    {tool_calls_to_execute, tool_results_for_limited_tools, new_tool_usage_counts} =
      Enum.reduce(tool_calls, {[], [], tool_usage_counts}, fn tool_call,
                                                              {exec_acc, limited_acc, counts_acc} ->
        tool_name_atom = String.to_atom(ToolCall.name(tool_call))
        current_count = Map.get(counts_acc, tool_name_atom, 0)

        if current_count < @tool_usage_limit do
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
        Context.append(llm_context, Context.assistant("", tool_calls: tool_calls_to_execute))
      else
        llm_context_with_assistant_tool_calls =
          Context.append(llm_context, Context.assistant("", tool_calls: tool_calls_to_execute))

        handle_tool_calls(
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

    params
    |> Map.put(:llm_context, updated_llm_context)
    |> Map.put(:tool_usage_counts, new_tool_usage_counts)
  end

  @doc """
  Processes a list of tool calls and returns an updated context.

  This is a pure function - given the same inputs, it always produces the same output.
  No side effects, no async operations, easy to test!

  ## Parameters

    - `tool_calls`: List of ReqLLM.ToolCall structs
    - `context`: Current ReqLLM.Context
    - `available_tools`: List of available tools
    - `chat_module`: Module implementing execute_tool/2

  ## Returns

  Updated ReqLLM.Context with tool results appended
  """
  @spec handle_tool_calls(list(), Context.t(), list(), module()) :: Context.t()
  def handle_tool_calls(tool_calls, context, available_tools, chat_module) do
    Enum.reduce(tool_calls, context, fn tool_call, acc_context ->
      process_tool_call(tool_call, available_tools, acc_context, chat_module)
    end)
  end

  @doc """
  Processes a single tool call and returns an updated context.

  Finds the tool, executes it, and adds the result (or error) to the context.
  """
  @spec process_tool_call(ReqLLM.ToolCall.t(), list(), Context.t(), module()) :: Context.t()
  def process_tool_call(tool_call, available_tools, context, chat_module) do
    name = ReqLLM.ToolCall.name(tool_call)
    args = ReqLLM.ToolCall.args_map(tool_call)

    case find_tool(available_tools, name) do
      nil -> add_tool_not_found_error(context, tool_call.id, name)
      tool -> execute_tool_and_add_result(tool, tool_call, args, context, chat_module)
    end
  end

  # Private helper functions

  @spec find_tool(list(), String.t()) :: ReqLLM.Tool.t() | nil
  defp find_tool(tools, name) do
    Enum.find(tools, fn tool -> tool.name == name end)
  end

  @spec add_tool_not_found_error(Context.t(), String.t(), String.t()) :: Context.t()
  defp add_tool_not_found_error(context, tool_call_id, tool_name) do
    error_message = "Error: Tool #{tool_name} not found."
    Context.append(context, Context.tool_result(tool_call_id, error_message))
  end

  @spec execute_tool_and_add_result(
          ReqLLM.Tool.t(),
          ReqLLM.ToolCall.t(),
          map(),
          Context.t(),
          module()
        ) :: Context.t()
  defp execute_tool_and_add_result(tool, tool_call, args, context, chat_module) do
    case chat_module.execute_tool(tool, args) do
      {:ok, result} -> add_tool_success_result(context, tool_call.id, result)
      {:error, reason} -> add_tool_execution_error(context, tool_call, reason)
    end
  end

  @spec add_tool_success_result(Context.t(), String.t(), term()) :: Context.t()
  defp add_tool_success_result(context, tool_call_id, result) do
    Context.append(context, Context.tool_result(tool_call_id, to_string(result)))
  end

  @spec add_tool_execution_error(Context.t(), ReqLLM.ToolCall.t(), term()) :: Context.t()
  defp add_tool_execution_error(context, tool_call, reason) do
    name = ReqLLM.ToolCall.name(tool_call)
    error_message = "Error executing tool #{name}: #{inspect(reason)}"
    Context.append(context, Context.tool_result(tool_call.id, error_message))
  end
end
