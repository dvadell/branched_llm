defmodule BranchedLLM.ProviderConfig do
  @moduledoc """
  Per-provider configuration lookup for multi-model support.

  Reads from `:branched_llm, :providers` config and provides
  endpoint resolution, API key management, and provider detection
  from model strings and structs.
  """

  def endpoints(provider \\ default_provider()) do
    config = provider_config(provider)

    base_url =
      Application.get_env(:branched_llm, :base_url) ||
        config[:base_url] ||
        "http://localhost:11434"

    {endpoint_base, model_endpoint} = build_model_endpoint(base_url)

    health_endpoint =
      resolve_health_endpoint(config[:health_endpoint], provider, model_endpoint, endpoint_base)

    %{
      base_url: endpoint_base,
      model_endpoint: model_endpoint,
      health_endpoint: health_endpoint
    }
  end

  defp build_model_endpoint(base_url) do
    uri = URI.parse(base_url)
    host = uri.host || "localhost"
    scheme = uri.scheme || "http"
    port_str = if uri.port, do: ":#{uri.port}", else: ""
    endpoint_base = "#{scheme}://#{host}#{port_str}"

    model_endpoint =
      if String.ends_with?(base_url, "/v1") do
        base_url
      else
        endpoint_base <> "/v1"
      end

    {endpoint_base, model_endpoint}
  end

  defp resolve_health_endpoint(nil, :nvidia, model_endpoint, _endpoint_base) do
    model_endpoint <> "/models"
  end

  defp resolve_health_endpoint(nil, _provider, _model_endpoint, endpoint_base) do
    endpoint_base <> "/api/tags"
  end

  defp resolve_health_endpoint(custom, _provider, _model_endpoint, _endpoint_base) do
    custom
  end

  def api_key(provider \\ default_provider()) do
    config = provider_config(provider)

    global_key = Application.get_env(:req_llm, :"#{provider}_api_key")

    key =
      global_key ||
        case config[:api_key] do
          {:system, env_var} -> System.get_env(env_var)
          key when is_binary(key) -> key
          _ -> nil
        end

    key
  end

  def provider_config(provider) do
    providers = Application.get_env(:branched_llm, :providers, %{})
    providers[provider] || []
  end

  def resolve_provider(model_string) when is_binary(model_string) do
    case String.split(model_string, ":", parts: 2) do
      [provider_str, _model_id] ->
        try do
          String.to_existing_atom(provider_str)
        rescue
          ArgumentError -> String.to_atom(provider_str)
        end

      _ ->
        :openai
    end
  end

  def resolve_provider(%{provider: provider}) when is_atom(provider) do
    provider
  end

  def resolve_provider(%LLMDB.Model{provider: provider}) when is_atom(provider) do
    provider
  end

  def resolve_provider(_), do: default_provider()

  def default_provider do
    Application.get_env(:branched_llm, :default_provider, :openai)
  end
end
