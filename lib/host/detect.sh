#!/usr/bin/env bash
# Detects a repository's tools from its build files. Pure bash, grep, sed and find, because it
# runs on the host before any image exists. Source, do not execute.
DEFAULT_TERRAFORM=1.9.8
DEFAULT_GRADLE=8.10
DEFAULT_HELM=3.16.1
DEFAULT_MAVEN=3.9.9

# _files ROOT NAME: files called NAME, skipping vendored and generated trees.
_files() {
  find "$1" -maxdepth 5 \( -name .git -o -name node_modules -o -name .terraform -o -name target \
    -o -name build -o -name dist -o -name .agentic -o -name .venv \) -prune -o -type f -name "$2" -print 2>/dev/null
}
_major() { case "$1" in 1.*) cut -d. -f2 <<<"$1" ;; *) echo "${1%%[.+_-]*}" ;; esac; }
# _tv ROOT TOOL: the version .tool-versions gives TOOL, without a vendor prefix.
_tv() {
  [ -f "$1/.tool-versions" ] || return 0
  awk -v t="$2" '$1 == t {print $2; exit}' "$1/.tool-versions" | sed -E 's/^[a-z]+-//'
}

detect_tools() {
  local root="$1" f v javas=() notes=() out=()
  # Java
  v="$(_tv "$root" java)"
  if [ -n "$v" ]; then javas+=("$(_major "$v")")
  elif [ -f "$root/.java-version" ]; then javas+=("$(_major "$(tr -d '[:space:]' < "$root/.java-version")")")
  elif [ -f "$root/.sdkmanrc" ] && v="$(sed -nE 's/^java=([0-9.]+).*/\1/p' "$root/.sdkmanrc")" && [ -n "$v" ]; then javas+=("$(_major "$v")")
  else
    while IFS= read -r f; do
      while IFS= read -r v; do javas+=("$(_major "$v")"); done < <(
        sed -nE 's#.*<(maven\.compiler\.(release|source|target)|java\.version|release)>[[:space:]]*([0-9.]+)[[:space:]]*</.*#\3#p' "$f")
    done < <(_files "$root" pom.xml)
    while IFS= read -r f; do
      while IFS= read -r v; do javas+=("$(_major "$v")"); done < <(
        sed -nE 's/.*JavaVersion\.VERSION_(1_)?([0-9]+).*/\2/p; s/.*JavaLanguageVersion\.of\(([0-9]+)\).*/\1/p; s/.*(source|target)Compatibility[^0-9]*(1\.)?([0-9]+).*/\3/p' "$f")
    done < <(_files "$root" 'build.gradle*')
  fi
  if [ "${#javas[@]}" -gt 0 ]; then
    out+=("java=$(printf '%s\n' "${javas[@]}" | awk '$1 >= 8' | sort -rnu | paste -sd, -)")
  fi
  # Maven
  if [ -n "$(_files "$root" pom.xml)" ]; then
    v="$(sed -nE 's#.*apache-maven/([0-9]+\.[0-9]+\.[0-9]+)/.*#\1#p' "$root/.mvn/wrapper/maven-wrapper.properties" 2>/dev/null)"
    out+=("maven=${v:-$DEFAULT_MAVEN}")
  fi
  # Gradle
  if [ -n "$(_files "$root" 'build.gradle*')" ] || [ -f "$root/settings.gradle" ] || [ -f "$root/settings.gradle.kts" ]; then
    if [ -f "$root/gradlew" ]; then out+=("gradle=false"); notes+=("uses the Gradle wrapper (./gradlew); no system Gradle installed")
    else out+=("gradle=$DEFAULT_GRADLE"); notes+=("no Gradle wrapper; installs Gradle $DEFAULT_GRADLE, adjust tools.gradle"); fi
  fi
  # Node
  v="$(_tv "$root" nodejs)"
  [ -n "$v" ] || { [ -f "$root/.nvmrc" ] && v="$(tr -d '[:space:]v' < "$root/.nvmrc")"; }
  [ -n "$v" ] || { [ -f "$root/.node-version" ] && v="$(tr -d '[:space:]v' < "$root/.node-version")"; }
  [ -n "$v" ] || { [ -f "$root/package.json" ] && v="$(sed -nE 's/.*"node"[[:space:]]*:[[:space:]]*"[^0-9]*([0-9]+).*/\1/p' "$root/package.json" | head -1)"; }
  if [ -n "$v" ] && [[ "$v" =~ ^[0-9] ]]; then out+=("node=$(_major "$v")"); fi
  # Python
  v="$(_tv "$root" python)"
  [ -n "$v" ] || { [ -f "$root/.python-version" ] && v="$(tr -d '[:space:]' < "$root/.python-version")"; }
  [ -n "$v" ] || { [ -f "$root/pyproject.toml" ] && v="$(sed -nE 's/^requires-python[^0-9]*([0-9]+\.[0-9]+).*/\1/p' "$root/pyproject.toml" | head -1)"; }
  if [ -n "$v" ]; then out+=("python=$(cut -d. -f1-2 <<<"$v")")
  elif [ -f "$root/pyproject.toml" ] || [ -f "$root/requirements.txt" ]; then out+=("python=3.12"); fi
  # Terraform
  if [ -n "$(_files "$root" '*.tf')" ]; then
    v="$(_tv "$root" terraform)"
    [ -n "$v" ] || { [ -f "$root/.terraform-version" ] && v="$(tr -d '[:space:]' < "$root/.terraform-version")"; }
    [ -n "$v" ] || v="$(_files "$root" '*.tf' | xargs -r sed -nE 's/^[[:space:]]*required_version[[:space:]]*=[[:space:]]*"=?[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+)"[[:space:]]*$/\1/p' | head -1)"
    if [ -z "$v" ]; then v="$DEFAULT_TERRAFORM"; notes+=("no exact terraform version found; using $DEFAULT_TERRAFORM, adjust tools.terraform"); fi
    out+=("terraform=$v")
  fi
  # Go, .NET, Helm
  if [ -f "$root/go.mod" ]; then
    v="$(sed -nE 's/^go[[:space:]]+([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p' "$root/go.mod" | head -1)"
    if [ -n "$v" ]; then [[ "$v" =~ ^[0-9]+\.[0-9]+$ ]] && v="$v.0"; out+=("go=$v"); fi
  fi
  v="$(_files "$root" '*.csproj' | xargs -r sed -nE 's#.*<TargetFramework>net([0-9]+\.[0-9]+)</TargetFramework>.*#\1#p' | sort -rn | head -1)"
  if [ -n "$v" ]; then out+=("dotnet=$v"); fi
  if [ -n "$(_files "$root" Chart.yaml)" ]; then out+=("helm=$DEFAULT_HELM"); notes+=("Helm charts found; installs Helm $DEFAULT_HELM"); fi
  # Hints for the setup skill
  if [ -n "$(_files "$root" 'docker-compose*.yml')$(_files "$root" 'compose*.yaml')" ]; then
    notes+=("a compose file exists; tests that start containers need docker.socket: true")
  fi
  [ "${#out[@]}" -eq 0 ] || printf '%s\n' "${out[@]}"
  [ "${#notes[@]}" -eq 0 ] || printf 'note=%s\n' "${notes[@]}"
}

# render_tools DETECTION: the tools: block for agentic.yaml.
render_tools() {
  local line k v lines=() javas
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    k="${line%%=*}"; v="${line#*=}"
    case "$k" in
      note) ;;
      java) javas="${v//,/, }"; lines+=("  java: {versions: [$javas], default: ${v%%,*}}") ;;
      node) lines+=("  node: {versions: [$v], default: $v}") ;;
      python) lines+=("  python: [\"$v\"]") ;;
      gradle) if [ "$v" = false ]; then lines+=("  gradle: false"); else lines+=("  gradle: \"$v\""); fi ;;
      *) lines+=("  $k: \"$v\"") ;;
    esac
  done <<<"$1"
  if [ "${#lines[@]}" -eq 0 ]; then
    echo "tools: {}   # nothing detected; the base defaults apply (Java 21, Maven, Node 22, Python 3.12)"
  else
    echo "tools:"; printf '%s\n' "${lines[@]}"
  fi
}

# slugify TEXT: a valid project name.
slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-63
}
