import Config

config :branched_llm,
  ai_model: System.get_env("LLM_MODEL") || "ollama:cara-cpu",
  base_url: System.get_env("LLM_BASE_URL") || "http://host.docker.internal:11434"
