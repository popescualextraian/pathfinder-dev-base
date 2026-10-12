#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  make_agentic_dir
  make_task_dir
  G="$AGENTIC_DIR/task/gate.sh"
}

allow() { make_task_dir "$@"; }
pay() { jq -cn --arg c "$1" --arg t "${2:-Bash}" '{tool_name: $t, tool_input: {command: $c}}'; }
gate() { pay "$@" | bash "$G"; }
blocked() { run gate "$@"; [ "$status" -eq 2 ] || { echo "not blocked: $1 ($output)"; return 1; }; }
allowed() { run gate "$@"; [ "$status" -eq 0 ] || { echo "blocked: $1 ($output)"; return 1; }; }

@test "other tools and empty commands pass" {
  run bash "$G" <<<'{"tool_name":"Edit","tool_input":{"file_path":"x"}}'
  [ "$status" -eq 0 ]
  allowed ""
  allowed "git status && git commit -m 'push it'"
}

@test "git push needs push, however the command is written" {
  blocked "git push origin HEAD"
  [[ "$output" == "agentic gate: git push is not in allowed_actions; not allowed in this task. Use agentic-ask if you need it." ]]
  blocked "git -C /work push"
  blocked "cd /work && git push"
  blocked "FOO=1 sudo -u dev env A=b git push"
  blocked "bash -c \"git push\""
  blocked "timeout 30 git push"
  blocked 'echo $(git push)'
  blocked 'echo `git push`'
  blocked $'git \\\n push'
  blocked "/usr/bin/git push"
  allow push
  allowed "git push origin HEAD"
}

@test "opening a pull request needs open-pr; merging is never allowed" {
  blocked "gh pr create --fill"
  blocked "gh -R team/x pr create"
  blocked "glab mr create"
  allow push open-pr
  allowed "gh pr create --fill"
  allowed "glab mr create"
  blocked "gh pr merge 12"
  [[ "$output" == *"merging is never allowed"* ]]
  blocked "glab mr merge 3"
  allowed "gh pr view 12"
}

@test "deploy-like commands need deploy:<target> and must name the target" {
  blocked "terraform apply"
  [[ "$output" == *"deploy is not in allowed_actions"* ]]
  allow deploy:sandbox
  blocked "terraform apply -auto-approve"
  [[ "$output" == *"must name the allowed target sandbox"* ]]
  allowed "terraform workspace select sandbox"
  allowed "TF_WORKSPACE=sandbox terraform -chdir=infra apply -auto-approve"
  allowed "terraform plan"
  allowed "kubectl -n sandbox apply -f k8s/"
  allowed "kubectl get pods -n other"
  blocked "helm upgrade api ./chart -n other"
  allowed "helm upgrade api ./chart -n sandbox"
  allowed "make deploy WS=sandbox"
  blocked "make -C infra apply"
  allowed "make test"
}

@test "every built-in deploy tool is recognised" {
  for c in "npx cdk deploy" "cdk destroy" "sam deploy" "serverless deploy" "sls deploy" \
           "az deployment group create -g rg" "aws --region eu-central-1 cloudformation deploy --stack-name s" \
           "aws cloudformation delete-stack --stack-name s" "helm uninstall api" "kubectl rollout restart deploy/api" \
           "terraform destroy" "tofu apply"; do
    blocked "$c"
  done
  allowed "aws s3 ls"
  allowed "kubectl logs api"
}

@test "protected environments are always blocked" {
  allow push deploy:prod
  blocked "terraform workspace select prod"
  blocked "aws --profile prod-admin s3 ls"
  [[ "$output" == *"protected environment"* ]]
  blocked "WORKSPACE=production make deploy"
  allowed "git push origin HEAD"
  AGENTIC_GATE_PROTECTED=live blocked "helm upgrade api ./chart -n live"
}

@test "without a task record the gate reads AGENTIC_ALLOWED_ACTIONS" {
  rm "$AGENTIC_TASK_DIR/state.json"
  blocked "git push"
  AGENTIC_ALLOWED_ACTIONS="push, open-pr" allowed "git push"
  AGENTIC_ALLOWED_ACTIONS="push, open-pr" allowed "gh pr create"
}

@test "Copilot's shell tool is gated too" {
  run bash "$G" < "$REPO_ROOT/tests/fixtures/hooks/copilot/pretooluse-bash.json"
  [ "$status" -eq 2 ]
  [[ "$output" == *"merging is never allowed"* ]]
}

@test "the ask-guard blocks both harnesses' choosers and nothing else" {
  A="$AGENTIC_DIR/task/ask-guard.sh"
  run bash "$A" < "$REPO_ROOT/tests/fixtures/hooks/claude/pretooluse-ask.json"
  [ "$status" -eq 2 ]
  [ "$output" = "Use agentic-ask; nobody can answer a chooser here." ]
  run bash "$A" < "$REPO_ROOT/tests/fixtures/hooks/copilot/pretooluse-ask.json"
  [ "$status" -eq 2 ]
  run bash "$A" <<<'{"tool_name":"ExitPlanMode","tool_input":{}}'
  [ "$status" -eq 2 ]
  run bash "$A" < "$REPO_ROOT/tests/fixtures/hooks/claude/pretooluse-bash.json"
  [ "$status" -eq 0 ]
}

@test "control keywords, braces and a lone & do not hide a command" {
  blocked "if true; then git push; fi"
  blocked "for i in 1; do git push; done"
  blocked "true && { git push; }"
  blocked "git status & git push"
  allowed "git status 2>&1 | cat"
  allowed "git status &> /dev/null"
}

@test "bash -lc and bash -ec are command strings; path-qualified env and a backslash do not hide" {
  blocked "bash -lc 'git push'"
  blocked "bash -ec \"git push\""
  blocked "/usr/bin/env git push"
  blocked '\git push'
}

@test "gh api merge is never allowed" {
  allow push open-pr
  blocked "gh api -X PUT repos/o/r/pulls/3/merge"
  [[ "$output" == *"merging is never allowed"* ]]
  allowed "gh api repos/o/r/pulls/3"
}

@test "package scripts that deploy need deploy:<target>" {
  blocked "npm run deploy"
  blocked "pnpm run deploy:stack"
  blocked "yarn run destroy"
  blocked "npm run-script apply"
  allowed "npm run build"
  allow deploy:sandbox
  allowed "npm run deploy -- --stage sandbox"
}

@test "kubectl rollout status and history are read-only" {
  allow deploy:sandbox
  allowed "kubectl rollout status deploy/api"
  allowed "kubectl rollout history deploy/api"
  blocked "kubectl rollout restart deploy/api"
}

@test "without a task record the gate reads AGENTIC_ALLOWED_ACTIONS (hub mode)" {
  rm "$AGENTIC_TASK_DIR/state.json"
  blocked "git push"
  AGENTIC_ALLOWED_ACTIONS="push, open-pr" allowed "git push"
}

@test "copilot payloads with toolArgs as an object or a JSON string are gated" {
  run bash "$G" <<<'{"toolName":"bash","toolArgs":{"command":"git push"}}'
  [ "$status" -eq 2 ]
  run bash "$G" <<<'{"toolName":"bash","toolArgs":"{\"command\":\"git push\"}"}'
  [ "$status" -eq 2 ]
}
