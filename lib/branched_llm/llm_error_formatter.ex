defmodule BranchedLLM.LLMErrorFormatter do
  @moduledoc """
  Formats LLM errors into user-friendly messages.

  ## Example

      try do
        BranchedLLM.Chat.send_message("Hello", context)
      rescue
        e -> BranchedLLM.LLMErrorFormatter.format(e)
      end

  """

  @doc """
  Formats an exception into a user-friendly error message.

  Handles `ReqLLM.Error.API.Request` exceptions specially:
    * Status 429: Returns a "rate limited" message with optional retry delay
    * Other API errors: Returns a generic API error with status code
    * Generic errors: Returns the exception message
  """
  @spec format(Exception.t()) :: String.t()
  def format(%{
        __struct__: ReqLLM.Error.API.Request,
        status: 429,
        response_body: response_body
      }) do
    retry_delay = extract_retry_delay(response_body)
    base_message = "The AI is busy. Wait a moment and try again later."

    case retry_delay do
      nil -> base_message
      delay -> base_message <> " Please retry in #{delay}."
    end
  end

  def format(%{__struct__: ReqLLM.Error.API.Request, status: status}) do
    "API error (status #{status}). Please try again."
  end

  def format(exception) do
    "Error: #{Exception.message(exception)}"
  end

  @spec extract_retry_delay(map()) :: String.t() | nil
  defp extract_retry_delay(response_body) do
    details = Map.get(response_body, "details", [])

    case Enum.find(details, &retry_info?/1) do
      %{"retryDelay" => delay} when is_binary(delay) -> delay
      _ -> nil
    end
  end

  @spec retry_info?(map()) :: boolean()
  defp retry_info?(detail) do
    Map.get(detail, "@type") == "type.googleapis.com/google.rpc.RetryInfo"
  end
end
