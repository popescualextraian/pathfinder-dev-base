#!/usr/bin/env bats
load helpers

setup() {
  R="$BATS_TEST_TMPDIR/repo"; mkdir -p "$R"
  source "$REPO_ROOT/lib/host/detect.sh"
}

@test "an empty repository detects nothing" {
  run detect_tools "$R"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "Maven modules on Java 8 and 17, with the Maven wrapper's version" {
  mkdir -p "$R/old" "$R/new" "$R/.mvn/wrapper"
  printf '<project><properties><maven.compiler.source>1.8</maven.compiler.source></properties></project>\n' > "$R/old/pom.xml"
  printf '<project><properties><maven.compiler.release>17</maven.compiler.release></properties></project>\n' > "$R/new/pom.xml"
  printf 'distributionUrl=https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/3.8.8/apache-maven-3.8.8-bin.zip\n' > "$R/.mvn/wrapper/maven-wrapper.properties"
  run detect_tools "$R"
  grep -qx 'java=17,8' <<<"$output"
  grep -qx 'maven=3.8.8' <<<"$output"
}

@test "Gradle with a wrapper and a Java toolchain" {
  printf 'java { toolchain { languageVersion = JavaLanguageVersion.of(21) } }\n' > "$R/build.gradle.kts"
  touch "$R/gradlew"
  run detect_tools "$R"
  grep -qx 'java=21' <<<"$output"
  grep -qx 'gradle=false' <<<"$output"
  grep -q '^note=.*Gradle wrapper' <<<"$output"
}

@test "Gradle sourceCompatibility in its several spellings" {
  printf 'sourceCompatibility = JavaVersion.VERSION_1_8\n' > "$R/build.gradle"
  run detect_tools "$R"
  grep -qx 'java=8' <<<"$output"
  printf "sourceCompatibility = '11'\n" > "$R/build.gradle"
  run detect_tools "$R"
  grep -qx 'java=11' <<<"$output"
}

@test "Node from .nvmrc, falling back to package.json engines" {
  printf '{"engines": {"node": ">=18.0.0"}}\n' > "$R/package.json"
  run detect_tools "$R"
  grep -qx 'node=18' <<<"$output"
  echo v20.11.0 > "$R/.nvmrc"
  run detect_tools "$R"
  grep -qx 'node=20' <<<"$output"
}

@test "Python from .python-version or requires-python" {
  printf '[project]\nrequires-python = ">=3.11"\n' > "$R/pyproject.toml"
  run detect_tools "$R"
  grep -qx 'python=3.11' <<<"$output"
}

@test "Terraform: an exact required_version is used, a range gets the default and a note" {
  mkdir -p "$R/infra"
  printf 'terraform {\n  required_version = "1.5.7"\n}\n' > "$R/infra/main.tf"
  run detect_tools "$R"
  grep -qx 'terraform=1.5.7' <<<"$output"
  printf 'terraform {\n  required_version = ">= 1.5"\n}\n' > "$R/infra/main.tf"
  run detect_tools "$R"
  grep -qx 'terraform=1.9.8' <<<"$output"
  grep -q '^note=.*terraform' <<<"$output"
}

@test ".tool-versions wins for the tools it names" {
  printf 'java temurin-11.0.24+8\nnodejs 18.20.4\nterraform 1.6.6\n' > "$R/.tool-versions"
  printf 'terraform {\n  required_version = "1.5.7"\n}\n' > "$R/main.tf"
  run detect_tools "$R"
  grep -qx 'java=11' <<<"$output"
  grep -qx 'node=18' <<<"$output"
  grep -qx 'terraform=1.6.6' <<<"$output"
}

@test "Go, .NET and Helm" {
  printf 'module x\n\ngo 1.22\n' > "$R/go.mod"
  printf '<Project><PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup></Project>\n' > "$R/app.csproj"
  mkdir -p "$R/chart"; printf 'apiVersion: v2\nname: x\n' > "$R/chart/Chart.yaml"
  run detect_tools "$R"
  grep -qx 'go=1.22.0' <<<"$output"
  grep -qx 'dotnet=8.0' <<<"$output"
  grep -qx 'helm=3.16.1' <<<"$output"
}

@test "a compose file suggests the Docker socket" {
  printf 'services: {}\n' > "$R/docker-compose.yml"
  run detect_tools "$R"
  grep -q '^note=.*docker.socket' <<<"$output"
}

@test "node_modules and .git are never searched" {
  mkdir -p "$R/node_modules/x"; printf '<project><properties><java.version>11</java.version></properties></project>\n' > "$R/node_modules/x/pom.xml"
  run detect_tools "$R"
  [ -z "$output" ]
}

@test "render_tools turns a detection into the tools block, highest Java as default" {
  run render_tools $'java=17,8\nmaven=3.8.8\nterraform=1.5.7\nnote=hello'
  [ "${lines[0]}" = "tools:" ]
  grep -qx '  java: {versions: \[17, 8\], default: 17}' <<<"$output"
  grep -qx '  maven: "3.8.8"' <<<"$output"
  grep -qx '  terraform: "1.5.7"' <<<"$output"
}

@test "render_tools with nothing detected keeps the defaults" {
  run render_tools ''
  [ "$output" = "tools: {}   # nothing detected; the base defaults apply (Java 21, Maven, Node 22, Python 3.12)" ]
}
