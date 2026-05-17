import Config

# All LLM configuration lives under :req_llm — BranchedLLM reads from here too
# Example for an openai-compatible LLM server
config :req_llm,
  openai: [
    base_url: System.get_env("LLM_BASE_URL")
  ],
  openai_api_key: System.get_env("NVIDIA_API_KEY"),
  model: "openai:z-ai/glm-5.1"
