import Config

config :branched_llm,
  ai_model: System.get_env("LLM_MODEL") || "openai:cara-cpu",
  base_url: System.get_env("LLM_BASE_URL") || "http://host.docker.internal:11434",
  api_key: System.get_env("NVIDIA_API_KEY") || "ollama"
