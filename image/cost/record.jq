# The readers' check of schema/cost-record.schema.json: valid_record is true for a record every
# reader accepts. Keep the two in step; tests/bats/cost-summary.bats checks the fixtures with both.
def _count: type == "number" and . >= 0 and . == floor;
def _tokens: type == "object" and all(.input, .output, .cache_read, .cache_write; _count);
def _source: . == "estimate" or . == "billed-credits" or . == "unknown";
def _costs: type == "object" and all(to_entries[]; (.key | _source) and (.value | type == "number" and . >= 0));
def valid_record:
  type == "object" and .schema == "cost-record/v1"
  and (.ts | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
  and (.project | type == "string")
  and (.harness | type == "string" and test("^[a-z0-9][a-z0-9-]{0,39}$"))
  and (.session | type == "string" and length > 0 and length <= 200)
  and (.context | type == "object" and (.kind == "task" or .kind == "scheduled" or .kind == "dev")
       and ((.task // "") | type == "string") and ((.schedule // "") | type == "string"))
  and (.models | type == "array" and all(.[]; _tokens and (.model | type == "string")
       and (.cost | type == "number" and . >= 0) and (.cost_source | _source)))
  and (.totals | _tokens and (.cost | _costs));
