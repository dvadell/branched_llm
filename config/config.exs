import Config

config :branched_llm,
  ai_model: System.get_env("LLM_MODEL") || "ollama:cara-cpu",
  base_url: System.get_env("LLM_BASE_URL") || "http://host.docker.internal:11434",
  default_provider: :openai

config :branched_llm, :providers,
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
