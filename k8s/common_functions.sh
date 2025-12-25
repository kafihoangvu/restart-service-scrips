#!/bin/sh

countdown() {
    local seconds=$1
    local message=${2:-"Waiting"}
    if [ "$seconds" -gt 0 ] 2>/dev/null; then
        printf "  ⏳ %s (%ds)...\n" "$message" "$seconds"
        sleep "$seconds"
    fi
}

restart_group_pods() {
    local step_num=$1
    local group_name=$2
    local namespace=$3
    local wait_time=${4:-30}
    shift 4
    
    echo ""
    echo "Step $step_num: Restarting $group_name workloads in namespace $namespace"
    
    # Tìm các Deployment/StatefulSet theo pattern
    local temp_workloads_file
    temp_workloads_file=$(mktemp 2>/dev/null || echo "/tmp/workloads_$$")
    > "$temp_workloads_file"
    
    for pattern; do
        local found_workloads
        found_workloads=$(kubectl get deploy,statefulset -n "$namespace" --no-headers 2>/dev/null \
            -o custom-columns=KIND:.kind,NAME:.metadata.name \
            | awk -v p="$pattern" '$2 ~ p {print $1 " " $2}')
        if [ -n "$found_workloads" ]; then
            printf "%s\n" "$found_workloads" >> "$temp_workloads_file"
        else
            echo "  ⚠ No workloads found for pattern '$pattern' in namespace '$namespace'"
        fi
    done
    
    if [ ! -s "$temp_workloads_file" ] 2>/dev/null; then
        echo "  ⚠ No workloads found for $group_name, skipping..."
        rm -f "$temp_workloads_file" 2>/dev/null || true
        return 0
    fi
    
    # Loại trùng lặp và chuẩn hóa danh sách workload
    sort -u "$temp_workloads_file" -o "$temp_workloads_file" 2>/dev/null || true
    
    local workload_count
    workload_count=$(wc -l < "$temp_workloads_file" 2>/dev/null | tr -d ' ' || echo "0")
    workload_count=${workload_count:-0}
    
    if [ "$workload_count" -eq 0 ] 2>/dev/null; then
        echo "  ⚠ No workloads found for $group_name, skipping..."
        rm -f "$temp_workloads_file" 2>/dev/null || true
        return 0
    fi
    
    echo "  ✓ Found $workload_count workload(s):"
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        echo "    - $line"
    done < "$temp_workloads_file"
    echo ""
    
    # Rollout restart cho từng workload
    local restarted=0
    local failed=0
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        local kind name
        kind=$(printf "%s" "$line" | awk '{print $1}')
        name=$(printf "%s" "$line" | awk '{print $2}')
        [ -z "$kind" ] && continue
        [ -z "$name" ] && continue
        
        local kind_lc
        kind_lc=$(printf "%s" "$kind" | tr 'A-Z' 'a-z')
        
        if kubectl rollout restart "$kind_lc/$name" -n "$namespace" >/dev/null 2>&1; then
            restarted=$((restarted + 1))
        else
            failed=$((failed + 1))
            echo "  ✗ Failed to rollout restart $kind_lc/$name"
        fi
    done < "$temp_workloads_file"
    
    rm -f "$temp_workloads_file" 2>/dev/null || true
    
    echo "  ✓ $group_name: $restarted restarted, $failed failed"
    if [ $wait_time -gt 0 ]; then
        countdown "$wait_time" "Stabilizing $group_name pods"
    fi
}

show_pod_status() {
    local pattern=$1
    local namespace=$2
    echo ""
    echo "Current pod status:"
    kubectl get pods -n "$namespace" | grep -E "$pattern" || echo "  (No pods found)"
}
