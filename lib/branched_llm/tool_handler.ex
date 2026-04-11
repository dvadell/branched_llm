defmodule BranchedLLM.ToolHandler do
  @moduledoc """
  Handles tool execution and context management for BranchedLLM.
  """

  alias ReqLLM.Context
  require Logger

  @doc """
  Processes a list of tool calls and returns an updated context.
  """
  @spec handle_tool_calls(list(), Context.t(), list(), module()) :: Context.t()
  def handle_tool_calls(tool_calls, context, available_tools, chat_module) do
    Enum.reduce(tool_calls, context, fn tool_call, acc_context ->
      process_tool_call(tool_call, available_tools, acc_context, chat_module)
    end)
  end

  @doc """
  Processes a single tool call and returns an updated context.
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

  defp find_tool(tools, name) do
    Enum.find(tools, fn tool -> tool.name == name end)
  end

  defp add_tool_not_found_error(context, tool_call_id, tool_name) do
    error_message = "Error: Tool #{tool_name} not found."
    Context.append(context, Context.tool_result(tool_call_id, error_message))
  end

  defp execute_tool_and_add_result(tool, tool_call, args, context, chat_module) do
    Logger.info("Calling tool '#{tool.name}' with args: #{inspect(args)}")

    case chat_module.execute_tool(tool, args) do
      {:ok, result} ->
        Logger.info("Got this answer: #{result}")
        Context.append(context, Context.tool_result(tool_call.id, to_string(result)))

      {:error, reason} ->
        name = ReqLLM.ToolCall.name(tool_call)
        error_message = "Error executing tool #{name}: #{inspect(reason)}"
        Context.append(context, Context.tool_result(tool_call.id, error_message))
    end
  end
end
