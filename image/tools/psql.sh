#!/usr/bin/env bash
# PostgreSQL client of the given major from the PGDG apt repository.
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
do_install() {
  local codename key=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
  dpkg -s "postgresql-client-$1" >/dev/null 2>&1 && return 0
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  install -d "$(dirname "$key")"
  fetch https://www.postgresql.org/media/keys/ACCC4CF8.asc "$key"
  echo "deb [signed-by=$key] https://apt.postgresql.org/pub/repos/apt $codename-pgdg main" > /etc/apt/sources.list.d/pgdg.list
  apt-get update
  apt-get install -y --no-install-recommends "postgresql-client-$1"
  rm -rf /var/lib/apt/lists/*
}
do_env() { echo "PATH=/usr/lib/postgresql/$1/bin"; }
do_check() { "/usr/lib/postgresql/$1/bin/psql" --version 2>/dev/null; }
preset_main "$@"
