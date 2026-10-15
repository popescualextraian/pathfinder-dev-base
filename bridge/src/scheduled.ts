// The texts of a scheduled run (spec 2026-10-15-schedule-design §6.2). The note follows the first
// prompt after SCHEDULED_MARK, so the task text stays first.
export const SCHEDULED_MARK = "\n\n[scheduled run]\n";
export const SCHEDULED_NOTE = `${SCHEDULED_MARK}Nobody watches this run and nobody answers questions until it has ended. ` +
  "Decide what you can decide yourself and note each decision. Do not wait for answers: agentic-ask still records a " +
  "question, so ask when only a human can decide, then continue with what does not depend on it. When the work is " +
  "done, end your turn; you will then be asked for a summary.";
export const SUMMARY_PROMPT = "The run ends now. Write the summary for the person who scheduled it, in Markdown, at most " +
  "about 300 words: what you did; where the result is (branch, pull request, files); the decisions you made; open " +
  "questions and refused actions; what a human should do next. Do not run any more tools.";
export const TIMEOUT_NOTE = "The time for this run is up. Stop working.";
export const NO_SUMMARY = "No summary: the run timed out.";
