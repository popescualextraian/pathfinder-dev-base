#!/usr/bin/env bash
# agentic cost (docs/cost.md): the project's ledger, written by the cost plugin in the project's
# containers, read as untrusted (spec C9) and summed by the image's summary.jq (spec C8).

# cost_dir: the project's ledger folder, mounted at /cost in every container of the project.
cost_dir() { printf '%s/%s/cost\n' "$(realpath -m -- "$AGENTIC_WORKSPACES")" "$(project_name)"; }

# valid_day D: D is a calendar day, YYYY-MM-DD.
valid_day() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && date -d "$1" +%F >/dev/null 2>&1; }

# cost_ledger: the ledger's content, or nothing when there is none. The agent writes it: a symlink
# on the way, anything but a regular file, or more than AGENTIC_COST_LEDGER_MAX bytes is refused.
cost_ledger() {
  local f max="${AGENTIC_COST_LEDGER_MAX:-67108864}"
  f="$(cost_dir)/ledger.jsonl"
  if [ ! -e "$f" ] && [ ! -L "$f" ] && bind_src_ok "$(cost_dir)"; then return 0; fi
  { bind_src_ok "$f" && [ -f "$f" ]; } || die "$f is not a regular file or goes through a symlink; refused"
  [ "$(stat -c %s -- "$f")" -le "$max" ] || die "$f is over $max bytes; rotate it (move it aside) and run again"
  # the container appends live: cap the read itself, a cut line counts as skipped
  { read_agent_file "$f" | head -c "$max"; } || true  # dd gets SIGPIPE when head stops early
}

# cost_table: a cost-summary/v1 (stdin) as a table. Estimates and credits keep their own columns
# (spec C7); text from the ledger loses its control characters.
cost_table() {
  jq -r '
    def c: tostring | gsub("[[:cntrl:]]"; " ");
    def pad($n): c | if length < $n then . + (" " * ($n - length)) else . + " " end;
    def tok: if . >= 1000000 then "\(. / 100000 | floor / 10)M" elif . >= 1000 then "\(. / 100 | floor / 10)k" else tostring end;
    def usd: if . == null then "-" else (. * 100 | round) as $c
      | "\($c / 100 | floor).\($c % 100 | tostring | if length < 2 then "0" + . else . end)" end;
    def name: .key | [.kind, .task, .schedule, .harness, .session, .model, .day] | map(values)
      | if length == 0 then "-" else join(" ") end;
    def row($name): [($name | pad(36)), (.sessions | pad(9)),
        (.totals | (.input, .output, .cache_read, .cache_write) | tok | pad(9)),
        ((.totals.cost.estimate | usd) + (if .totals.cost | has("unknown") then "+?" else "" end) | pad(10)),
        (.totals.cost["billed-credits"] | usd)] | join("");
    ("GROUP" | pad(36)) + ("SESSIONS" | pad(9)) + ("INPUT" | pad(9)) + ("OUTPUT" | pad(9))
      + ("CACHE R" | pad(9)) + ("CACHE W" | pad(9)) + ("EST. USD" | pad(10)) + "CREDITS USD",
    (.groups[] | row(name)),
    ({sessions, totals} | row("total")),
    (if .skipped_lines > 0 then "\(.skipped_lines) ledger lines skipped: not a cost-record/v1" else empty end),
    (if .totals.cost | has("unknown") then "+? some tokens have no price: agentic cost --by model" else empty end)'
}

cmd_cost() {
  need_config
  local since="" until="" task="" schedule="" by=context json=0 out
  while [ $# -gt 0 ]; do
    case "$1" in
      --since|--until) optval "$@"; valid_day "$2" || die "$1 takes a day, YYYY-MM-DD"
        if [ "$1" = --since ]; then since="$2"; else until="$2"; fi; shift 2 ;;
      --task) optval "$@"; valid_task_id "$2" || die "--task takes a task id"; task="$2"; shift 2 ;;
      --schedule) optval "$@"; valid_sched_name "$2" || die "--schedule takes a schedule name"; schedule="$2"; shift 2 ;;
      --by) optval "$@"; [[ "$2" =~ ^(context|model|day)$ ]] || die "--by takes context, model or day"
        by="$2"; shift 2 ;;
      --json) json=1; shift ;;
      *) die "usage: agentic cost [--since D] [--until D] [--task ID] [--schedule NAME] [--by context|model|day] [--json]" ;;
    esac
  done
  out="$(cost_ledger | jq -n -R -L "$AGENTIC_ROOT/image/cost" --arg project "$(project_name)" \
    --arg since "$since" --arg until "$until" --arg task "$task" --arg schedule "$schedule" \
    --arg by "$by" -f "$AGENTIC_ROOT/image/cost/summary.jq")" || exit 1
  if [ "$json" = 1 ]; then printf '%s\n' "$out"; else cost_table <<<"$out"; fi
}
