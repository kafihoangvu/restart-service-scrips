#!/bin/sh
set -e

SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"
. "$SCRIPT_DIR/common_functions.sh"

restart_group_pods 1 "AAA" "kx-customers-stg" 30 \
  "^aaa" 
