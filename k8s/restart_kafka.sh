#!/bin/sh
set -e

SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"
. "$SCRIPT_DIR/common_functions.sh"

restart_group_pods 1 "Kafka" "kafka-data-uat" 30 \
  "^kafka"

restart_group_pods 2 "Domain Business" "kx-customers-uat" 30 \
  "^user-utilities" \
  "^asset-realtime"

restart_group_pods 3 "Domain Common" "kx-customers-uat" 30 \
  "^aaa" \
  "^notification" \
  "^configuration"

echo ""
echo "=========================================="
echo "FINAL POD STATUS"
echo "=========================================="

echo ""
echo "[Kafka - kafka-data-uat]"
show_pod_status "^kafka" "kafka-data-uat"

echo ""
echo "[Domain Business - kx-customers-uat]"
show_pod_status "^user-utilities|^asset-realtime" "kx-customers-uat"

echo ""
echo "[Domain Common - kx-customers-uat]"
show_pod_status "^aaa|^notification|^configuration" "kx-customers-uat"
