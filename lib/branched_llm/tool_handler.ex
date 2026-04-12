defmodule BranchedLLM.ToolHandler do
  @moduledoc """
  Handles tool execution and context management.

  This module contains pure functions for processing tool calls and managing
  the context updates.

  ## Example

      tool_call = ReqLLM.ToolCall.new("call_1", "calculator", %{"expression" => "2+2"})
      context = ReqLLM.Context.new([])
      tools = [CalculatorTool.calculator()]

      BranchedLLM.ToolHandler.handle_tool_calls([tool_call], context, tools, MyChatModule)

  """

  alias ReqLLM.Context
  require Logger

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
      nil ->
        add_tool_not_found_error(context, tool_call.id, name)

      tool ->
        execute_tool_and_add_result(tool, tool_call, args, context, chat_module)
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
    Logger.info("Calling tool '#{tool.name}' with args: #{inspect(args)}")

    case chat_module.execute_tool(tool, args) do
      {:ok, result} ->
        Logger.info("Got this answer: #{result}")
        add_tool_success_result(context, tool_call.id, result)

      {:error, reason} ->
        add_tool_execution_error(context, tool_call, reason)
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
