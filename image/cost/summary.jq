# cost-summary/v1 of a ledger: raw lines on stdin, run as jq -n -R -L <this dir> -f summary.jq with
# --arg project, since, until, task, schedule, by ("" = not set). The one place that aggregates
# (spec C8).
include "record";

def _set: if . == "" then null else . end;
def _addcost($b): reduce ($b | to_entries[]) as $e (.; .[$e.key] = ((.[$e.key] // 0) + $e.value));
def _sum: reduce .[] as $r ({input: 0, output: 0, cache_read: 0, cache_write: 0, cost: {}};
  .input += $r.input | .output += $r.output | .cache_read += $r.cache_read
  | .cache_write += $r.cache_write | .cost |= _addcost($r.cost));
# _rows: one row per model of a record; a record without models gives one row from its totals
def _rows: . as $r
  | (if (.models | length) > 0 then .models[] | .cost = {(.cost_source): .cost}
     else .totals + {model: "unknown"} end)
  | {sid: "\($r.harness)/\($r.session)", ts: $r.ts, context: $r.context, harness: $r.harness,
     session: $r.session, model, input, output, cache_read, cache_write, cost};
def _key($by):
  if $by == "model" then {harness, model}
  elif $by == "day" then {day: .ts[0:10]}
  else .context end;
# _in: both days inclusive, compared at the precision given
def _in($since; $until): ($since == null or .ts[0:($since | length)] >= $since)
  and ($until == null or .ts[0:($until | length)] <= $until);

[inputs | select(length > 0) | (try fromjson catch null)] as $lines
| ($lines | map(select(. != null and valid_record))) as $ok
| {since: ($since | _set), until: ($until | _set), task: ($task | _set),
   schedule: ($schedule | _set), by: (($by | _set) // "context")} as $f
# snapshots are cumulative and appended in order: a session's last line is its total (C3)
| ([reduce $ok[] as $r ({}; .["\($r.harness)/\($r.session)"] = $r) | .[]]
   | map(select(_in($f.since; $f.until)
       and ($f.task == null or .context.task == $f.task)
       and ($f.schedule == null or .context.schedule == $f.schedule)))
   | map(_rows)) as $rows
| {schema: "cost-summary/v1", project: $project, filter: $f,
   groups: ($rows | group_by(_key($f.by))
     | map({key: (.[0] | _key($f.by)), sessions: (map(.sid) | unique | length), last: (map(.ts) | max),
            totals: _sum,
            models: (group_by([.harness, .model]) | map(_sum + {harness: .[0].harness, model: .[0].model}))})
     | sort_by(.last) | reverse),
   sessions: ($rows | map(.sid) | unique | length),
   totals: ($rows | _sum),
   skipped_lines: (($lines | length) - ($ok | length))}
