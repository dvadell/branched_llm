import Config

config :branched_llm,
  ai_model: "openai:cara-cpu",
  base_url: "http://host.docker.internal:11434"

# ReqLLM expects configuration for its adapters
# You can also set the OPENAI_API_KEY environment variable
config :req_llm,
  openai: [
    api_key: "ollama"
  ],
  # Some versions of ReqLLM might expect a flat key as well
  openai_api_key: "ollama"
