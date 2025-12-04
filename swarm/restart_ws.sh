SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/common_functions.sh"

echo "=========================================="
echo "RESTART WEBSOCKET AND DEPENDENCIES"
echo "=========================================="

restart_group_services 1 "WebSocket Servers" 30 \
  "^kafi_ws" \
  "^kafi_kapi-market-ws" \
  "^kafi_kapi-trading-ws"

restart_group_services 2 "SCC Services" 30 \
  "^kafi_scc-redis" \
  "^kafi_kapi-market-scc-redis"

restart_group_services 3 "Domain Common" 30 \
  "^kafi_notification"

restart_group_services 4 "Domain Business" 30 \
  "^kafi_asset-realtime"

restart_group_services 5 "Domain Market" 30 \
  "^kafi_market-realtime"

restart_group_services 6 "Domain MO" 30 \
  "^kafi_basket-order"

restart_group_services 7 "Domain Trading" 30 \
  "^kafi_retail-conditional-order"

restart_group_services 8 "Domain GBI" 30 \
  "^kafi_gbi-pnl-mgmt" \
  "^kafi_gbi-subscribe-mgmt" \
  "^kafi_gbi-report"

restart_group_services 9 "Event Source" 30 \
  "^kafi_fds-event" \
  "^kafi_kapi-fds-event"

echo ""
echo "=========================================="
echo "✓ ALL WEBSOCKET DEPENDENT SERVICES RESTARTED"
echo "=========================================="
echo ""
echo "Lưu ý: cần vào 43.161 restart pairs-trading và flex-event"

