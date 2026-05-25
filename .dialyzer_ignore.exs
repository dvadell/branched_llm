[
  # ReqLLM references LLMDB.Model.t/0 which is a transitive dependency
  # not included in this project's Dialyzer PLT.
  # The error is in req_llm (the dependency) not in our code!
  {"lib/req_llm/stream_response.ex", :unknown_type},

  # Dialyzer cannot fully type ReqLLM.StreamResponse.t/0 because it depends
  # on LLMDB.Model.t/0 (unknown type from transitive dep not in PLT). This
  # causes Dialyzer to infer that __MODULE__.stream_text/3 (which delegates
  # to ReqLLM.stream_text/3) only returns {:error, _}, making the {:ok, _}
  # branch in call_llm/3 appear unreachable. At runtime, {:ok, %ContentResult{}},
  # %ToolCallResult{}, and %EmptyResult{} are all reachable (confirmed by
  # passing tests at high coverage).
  {"lib/branched_llm/chat.ex", :pattern_match_cov},

  # Same root cause as :pattern_match_cov above. Because Dialyzer thinks
  # call_llm/3 only returns {:error, _}, the success path through
  # unwrap_call_llm_result/2 → inject_context_builder/2 is deemed unreachable.
  # The function IS called at runtime (all test suites pass).
  {"lib/branched_llm/chat.ex", :unused_fun}
]
