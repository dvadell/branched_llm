defmodule BranchedLLM.ProviderConfigTest do
  use ExUnit.Case, async: false

  alias BranchedLLM.ProviderConfig

  describe "endpoints/1" do
    test "returns correct endpoints for openai provider" do
      put_test_providers()
      eps = ProviderConfig.endpoints(:openai)
      assert eps.base_url == "http://openai.test:4000"
      assert eps.model_endpoint == "http://openai.test:4000/v1"
    after
      restore_providers()
    end

    test "returns correct endpoints for ollama provider" do
      put_test_providers()
      eps = ProviderConfig.endpoints(:ollama)
      assert eps.base_url == "http://ollama.test:11434"
      assert eps.model_endpoint == "http://ollama.test:11434/v1"
      assert eps.health_endpoint == "http://ollama.test:11434/api/tags"
    after
      restore_providers()
    end

    test "returns correct health endpoint for nvidia provider" do
      put_test_providers()
      eps = ProviderConfig.endpoints(:nvidia)
      assert eps.model_endpoint == "https://nvidia.test/v1"
      assert eps.health_endpoint == "https://nvidia.test/v1/models"
    after
      restore_providers()
    end

    test "global base_url overrides per-provider base_url" do
      put_test_providers()
      Application.put_env(:branched_llm, :base_url, "http://override.test:9999")

      eps = ProviderConfig.endpoints(:openai)
      assert eps.base_url == "http://override.test:9999"
      assert eps.model_endpoint == "http://override.test:9999/v1"
    after
      Application.delete_env(:branched_llm, :base_url)
      restore_providers()
    end

    test "falls back to default when no config" do
      delete_test_providers()
      Application.delete_env(:branched_llm, :base_url)

      eps = ProviderConfig.endpoints(:unknown_provider)
      assert eps.base_url == "http://localhost:11434"
      assert eps.model_endpoint == "http://localhost:11434/v1"
    after
      restore_providers()
    end

    test "custom health endpoint from provider config" do
      Application.put_env(:branched_llm, :providers,
        custom_provider: [
          base_url: "http://custom.test/v1",
          health_endpoint: "http://health.custom.test/status"
        ]
      )

      eps = ProviderConfig.endpoints(:custom_provider)
      assert eps.health_endpoint == "http://health.custom.test/status"
    after
      restore_providers()
    end
  end

  describe "api_key/1" do
    test "returns key for provider with string api_key" do
      put_test_providers()
      assert ProviderConfig.api_key(:openai) == "sk-openai-test"
    after
      restore_providers()
    end

    test "returns nil for provider with {:system, var} when env not set" do
      put_test_providers()
      System.delete_env("NVIDIA_API_KEY")
      assert ProviderConfig.api_key(:nvidia) == nil
    after
      restore_providers()
    end

    test "reads {:system, var} api_key from env" do
      put_test_providers()
      System.put_env("NVIDIA_API_KEY", "nv-test-key")
      assert ProviderConfig.api_key(:nvidia) == "nv-test-key"
    after
      System.delete_env("NVIDIA_API_KEY")
      restore_providers()
    end

    test "returns nil when no config exists" do
      delete_test_providers()
      assert ProviderConfig.api_key(:unknown) == nil
    after
      restore_providers()
    end

    test "global :req_llm config overrides per-provider api_key" do
      put_test_providers()
      Application.put_env(:req_llm, :openai_api_key, "global-override")
      assert ProviderConfig.api_key(:openai) == "global-override"
    after
      Application.delete_env(:req_llm, :openai_api_key)
      restore_providers()
    end
  end

  describe "resolve_provider/1" do
    test "extracts provider from model string" do
      assert ProviderConfig.resolve_provider("openai:gpt-4") == :openai
      assert ProviderConfig.resolve_provider("nvidia:mixtral") == :nvidia
    end

    test "falls back to default provider for unknown model string without colon" do
      assert ProviderConfig.resolve_provider("simple-model") == :openai
    end

    test "extracts provider from LLMDB.Model struct" do
      model = %LLMDB.Model{provider: :anthropic, id: "claude-3"}
      assert ProviderConfig.resolve_provider(model) == :anthropic
    end
  end

  describe "default_provider/0" do
    test "returns configured default provider" do
      Application.put_env(:branched_llm, :default_provider, :nvidia)
      assert ProviderConfig.default_provider() == :nvidia
    after
      Application.delete_env(:branched_llm, :default_provider)
    end

    test "falls back to :openai" do
      Application.delete_env(:branched_llm, :default_provider)
      assert ProviderConfig.default_provider() == :openai
    end
  end

  describe "provider_config/1" do
    test "returns config for known provider" do
      put_test_providers()
      config = ProviderConfig.provider_config(:openai)
      assert config[:base_url] == "http://openai.test:4000/v1"
      assert config[:api_key] == "sk-openai-test"
    after
      restore_providers()
    end

    test "returns empty list for unknown provider" do
      delete_test_providers()
      assert ProviderConfig.provider_config(:nonexistent) == []
    after
      restore_providers()
    end
  end

  defp put_test_providers do
    Application.put_env(:branched_llm, :providers,
      openai: [
        base_url: "http://openai.test:4000/v1",
        api_key: "sk-openai-test"
      ],
      nvidia: [
        base_url: "https://nvidia.test/v1",
        api_key: {:system, "NVIDIA_API_KEY"}
      ],
      ollama: [
        base_url: "http://ollama.test:11434",
        api_key: "ollama"
      ]
    )
  end

  defp delete_test_providers do
    Application.delete_env(:branched_llm, :providers)
  end

  defp restore_providers do
    # Restore the original config.exs providers
    Application.put_env(:branched_llm, :providers,
      openai: [
        base_url: System.get_env("LLM_BASE_URL") || "http://host.docker.internal:11434/v1",
        api_key: System.get_env("OPENAI_API_KEY") || "ollama"
      ],
      nvidia: [
        base_url: "https://integrate.api.nvidia.com/v1",
        api_key: {:system, "NVIDIA_API_KEY"}
      ],
      ollama: [
        base_url: System.get_env("LLM_BASE_URL") || "http://host.docker.internal:11434",
        api_key: "ollama"
      ]
    )
  end
end
