#!/bin/sh
set -e

if [ -z "$POD_PATTERN" ] || [ -z "$TARGET_NS" ]; then
  echo "Error: POD_PATTERN and TARGET_NS environment variables must be set"
  echo "Usage: POD_PATTERN='^pattern' TARGET_NS='namespace' /scripts/restart-pods.sh"
  exit 1
fi

echo "============================================"
echo "  Restart Pods"
echo "============================================"
echo "Started at: $(date)"
echo ""
echo "Pattern: $POD_PATTERN"
echo "Namespace: $TARGET_NS"
echo ""

# Tìm các pods có pattern
echo "Finding pods matching pattern '$POD_PATTERN' in namespace '$TARGET_NS'..."
PODS=$(kubectl get pods -n $TARGET_NS --no-headers 2>/dev/null | awk '{print $1}' | grep -E "$POD_PATTERN" || true)

if [ -z "$PODS" ]; then
  echo "✗ No pods found matching pattern '$POD_PATTERN'"
  exit 0
fi

POD_COUNT=$(echo "$PODS" | wc -l | tr -d ' ')
echo "✓ Found $POD_COUNT pod(s) matching pattern '$POD_PATTERN':"
echo "$PODS" | sed 's/^/  - /'
echo ""

RESTARTED=0
FAILED=0

for POD in $PODS; do
  echo "--- Restarting pod: $POD ---"
  
  POD_PHASE=$(kubectl get pod $POD -n $TARGET_NS -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  echo "  Current status: $POD_PHASE"
  
  if kubectl delete pod $POD -n $TARGET_NS --wait=false 2>&1; then
    echo "  ✓ Delete command sent successfully"
    RESTARTED=$((RESTARTED + 1))
    
    echo "  Waiting for pod to be recreated..."
    TIMEOUT=30
    ELAPSED=0
    while [ $ELAPSED -lt $TIMEOUT ]; do
      if kubectl get pod $POD -n $TARGET_NS &>/dev/null; then
        NEW_POD_PHASE=$(kubectl get pod $POD -n $TARGET_NS -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        if [ "$NEW_POD_PHASE" = "Running" ] || [ "$NEW_POD_PHASE" = "Pending" ]; then
          echo "  ✓ Pod recreated, new status: $NEW_POD_PHASE"
          break
        fi
      fi
      sleep 2
      ELAPSED=$((ELAPSED + 2))
    done
    
    if [ $ELAPSED -ge $TIMEOUT ]; then
      echo "  ⚠ Pod recreation timeout (waited ${TIMEOUT}s)"
    fi
  else
    echo "  ✗ Failed to delete pod $POD"
    FAILED=$((FAILED + 1))
  fi
  echo ""
done

echo "--- Restart Summary ---"
echo "  Total pods found: $POD_COUNT"
echo "  Successfully restarted: $RESTARTED"
echo "  Failed: $FAILED"
echo ""

# Hiển thị trạng thái pods sau khi restart
echo "Current pod status:"
kubectl get pods -n $TARGET_NS | grep -E "$POD_PATTERN" || echo "  (No pods found)"
echo ""

echo "============================================"
echo "Restart Completed"
echo "Completed at: $(date)"
echo "============================================"

