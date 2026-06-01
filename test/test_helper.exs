# Suppress Logger.info during tests (warnings and errors still visible)
Logger.configure(level: :warning)

# LLM_TEST_MODE controls which e2e tests run:
#   "bypass" (default) — bypass-only tests run, live tests excluded
#   "live"             — live tests run, bypass-only tests excluded
excluded_tags =
  case System.get_env("LLM_TEST_MODE") || "bypass" do
    "live" -> [:bypass_only]
    _ -> [:live]
  end

ExUnit.start(exclude: excluded_tags)

Mox.defmock(BranchedLLM.ChatMock, for: BranchedLLM.ChatBehaviour)
