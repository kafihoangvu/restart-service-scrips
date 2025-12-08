SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/common_functions.sh"

echo "=========================================="
echo "RESTART REDIS AND DEPENDENCIES"
echo "=========================================="

restart_group_services 1 "Redis Cluster" 30 \
  "^kafi_redis-master" \
  "^kafi_redis-sentinel" \
  "^kafi_redis-slave" 

restart_group_services 2 "scc redis & market realtime & gbi execution" 30 \
  "^kafi_scc-redis" \
  "^kafi_market-realtime" \
  "^kafi_gbi-execution" 

echo ""
echo "=========================================="
echo "✓ ALL REDIS DEPENDENT SERVICES RESTARTED"
echo "=========================================="
echo ""
echo "Lưu ý: cần vào 43.109 kiểm tra horizon-market và horizon-trading"
echo "Lưu ý: cần vào 43.165 kiểm tra fix-server"
echo "Lưu ý: cần vào 43.161 kiểm tra pairs-trading và flex-event"

