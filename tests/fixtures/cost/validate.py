"""validate.py SCHEMA FILE: one verdict per non-empty line of FILE (ok, bad or invalid-json)."""
import json
import sys

import jsonschema

validator = jsonschema.Draft202012Validator(json.load(open(sys.argv[1])))
for line in open(sys.argv[2]):
    line = line.strip()
    if not line:
        continue
    try:
        doc = json.loads(line)
    except ValueError:
        print("invalid-json")
        continue
    print("ok" if validator.is_valid(doc) else "bad")
