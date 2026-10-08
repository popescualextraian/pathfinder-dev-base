#!/usr/bin/env bats
load helpers

D="$REPO_ROOT/image/Dockerfile"

@test "the Dockerfile copies every part of the /opt/agentic contract" {
  for pair in "image/lib /opt/agentic/lib" "image/start.d /opt/agentic/start.d" "image/worker.d /opt/agentic/worker.d" \
              "image/tools /opt/agentic/tools" "image/bin /opt/agentic/bin" "derive /opt/agentic/derive" \
              "config /opt/agentic/config" "schema /opt/agentic/schema" "skills /opt/agentic/skills" \
              "image/entrypoint.sh /opt/agentic/entrypoint.sh" "image/profile.d/agentic.sh /etc/profile.d/agentic.sh"; do
    grep -Eq "^COPY( --chmod=[0-9]+)? $pair\$" "$D" || { echo "missing: COPY $pair"; false; }
  done
  grep -q 'ENTRYPOINT \["/opt/agentic/entrypoint.sh"\]' "$D"
}

@test "the base copies no certificate into the image" {
  run grep -Ei '^COPY .*\.(crt|pem)' "$D"
  [ "$status" -ne 0 ]
}

@test ".dockerignore keeps skills, config and schema in the build context" {
  for p in skills config schema image derive; do
    run grep -Eq "^/?$p/?$" "$REPO_ROOT/.dockerignore"
    [ "$status" -ne 0 ] || { echo "$p is ignored"; false; }
  done
}
