# Suppress Logger.info during tests (warnings and errors still visible)
Logger.configure(level: :warning)

ExUnit.start()
Mox.defmock(BranchedLLM.ChatMock, for: BranchedLLM.ChatBehaviour)
