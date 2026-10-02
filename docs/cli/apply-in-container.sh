#!/bin/bash
# Apply Undertow proxy-address-forwarding inside a JBoss EAP container.
# Run as the OS user that started the server (the official image uses jboss).
# Line endings must stay LF.
set -euo pipefail

MODE="${1:---check}"
UNDERTOW_SERVER="${UNDERTOW_SERVER:-default-server}"
UNDERTOW_HTTP_LISTENER="${UNDERTOW_HTTP_LISTENER:-default}"
CLI_CONTROLLER="${CLI_CONTROLLER:-remote+http://127.0.0.1:9990}"

if [[ -z "${JBOSS_HOME:-}" ]]; then
  if [[ -x /opt/eap/bin/jboss-cli.sh ]]; then
    JBOSS_HOME=/opt/eap
  elif [[ -x /opt/jboss/eap/bin/jboss-cli.sh ]]; then
    JBOSS_HOME=/opt/jboss/eap
  else
    echo "JBOSS_HOME is not set, and jboss-cli.sh was not found under /opt/eap or /opt/jboss/eap." >&2
    exit 1
  fi
fi
CLI="${JBOSS_HOME}/bin/jboss-cli.sh"
ADDR="/subsystem=undertow/server=${UNDERTOW_SERVER}/http-listener=${UNDERTOW_HTTP_LISTENER}"

fail_if_outcome_failed() {
  local text="$1"
  if printf '%s\n' "${text}" | grep -q '"outcome" => "failed"'; then
    printf '%s\n' "${text}" >&2
    echo "jboss-cli reported a failed outcome." >&2
    exit 1
  fi
}

cli_connect() {
  "${CLI}" --connect --controller="${CLI_CONTROLLER}" --commands="$1"
}

cmd_check() {
  echo "---- listeners and product version ----"
  local listed
  listed="$(cli_connect "/subsystem=undertow/server=${UNDERTOW_SERVER}:read-children-names(child-type=http-listener),/subsystem=undertow/server=${UNDERTOW_SERVER}:read-children-names(child-type=https-listener),/core-service=server-environment:read-attribute(name=product-version)")"
  fail_if_outcome_failed "${listed}"
  printf '%s\n' "${listed}"
  echo "---- ${ADDR} proxy-address-forwarding ----"
  local current
  current="$(cli_connect "${ADDR}:read-attribute(name=proxy-address-forwarding)")"
  fail_if_outcome_failed "${current}"
  printf '%s\n' "${current}"
}

cmd_apply() {
  local current
  current="$(cli_connect "${ADDR}:read-attribute(name=proxy-address-forwarding)")"
  fail_if_outcome_failed "${current}"
  printf '%s\n' "${current}"
  if printf '%s\n' "${current}" | grep -Eq '"result" => true'; then
    echo "proxy-address-forwarding is already true on ${ADDR}."
    exit 0
  fi
  local written
  written="$(cli_connect "${ADDR}:write-attribute(name=proxy-address-forwarding,value=true)")"
  fail_if_outcome_failed "${written}"
  printf '%s\n' "${written}"
  # reload drops the CLI connection. A non-zero status here can still mean the reload started.
  "${CLI}" --connect --controller="${CLI_CONTROLLER}" --commands="reload" || true
  local attempt result
  result=""
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    sleep 3
    if result="$(cli_connect "${ADDR}:read-attribute(name=proxy-address-forwarding)" 2>/dev/null)"; then
      if printf '%s\n' "${result}" | grep -Eq '"result" => true'; then
        printf '%s\n' "${result}"
        echo "Confirmed proxy-address-forwarding=true on ${ADDR}."
        exit 0
      fi
    fi
  done
  echo "Reload finished but the attribute did not read back as true." >&2
  printf '%s\n' "${result}" >&2
  exit 1
}

cmd_offline() {
  local config file
  config="${SERVER_CONFIG:-standalone.xml}"
  file="$(mktemp)"
  cat > "${file}" <<EOF
embed-server --std-out=echo --server-config=${config}
${ADDR}:write-attribute(name=proxy-address-forwarding,value=true)
stop-embedded-server
EOF
  echo "This mode edits ${config} with embed-server. Do not use it while EAP is running."
  echo "Target: ${ADDR}"
  "${CLI}" --file="${file}"
  rm -f "${file}"
}

case "${MODE}" in
  --check) cmd_check ;;
  --apply) cmd_apply ;;
  --offline) cmd_offline ;;
  *)
    echo "Usage: $0 [--check|--apply|--offline]" >&2
    exit 2
    ;;
esac
