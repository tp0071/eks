
#!/usr/bin/env bash
set -Eeuo pipefail

# -------- Configuration --------
SOURCE_CONTEXT="default"
OUTPUT_DIR="./k8s-export"

# Namespaces to export
NAMESPACES=(
  "ui"
  "catalog"
  "default"
  "catalog-pod"
)

# --------------------------------

command -v kubectl >/dev/null 2>&1 || {
  echo "ERROR: kubectl is not installed."
  exit 1
}

command -v yq >/dev/null 2>&1 || {
  echo "ERROR: yq v4 is required (https://github.com/mikefarah/yq)."
  exit 1
}

mkdir -p "$OUTPUT_DIR"

# Verify source context
kubectl config get-contexts "$SOURCE_CONTEXT" >/dev/null

for NS in "${NAMESPACES[@]}"; do
  echo "======================================"
  echo "Exporting namespace: $NS"
  echo "======================================"

  NS_DIR="$OUTPUT_DIR/$NS"
  mkdir -p "$NS_DIR"

  if ! kubectl --context="$SOURCE_CONTEXT" \
      get namespace "$NS" >/dev/null 2>&1; then
    echo "WARNING: Namespace '$NS' not found. Skipping."
    continue
  fi

  # Save namespace manifest
  kubectl --context="$SOURCE_CONTEXT" \
    get namespace "$NS" -o yaml |
    yq 'del(
      .status,
      .metadata.uid,
      .metadata.resourceVersion,
      .metadata.creationTimestamp,
      .metadata.generation,
      .metadata.managedFields
    )' > "$NS_DIR/namespace.yaml"

  # Discover all namespaced resource types supported by this cluster.
  mapfile -t RESOURCE_TYPES < <(
    kubectl --context="$SOURCE_CONTEXT" api-resources \
      --verbs=list --namespaced=true -o name |
      sort -u
  )

  for RESOURCE in "${RESOURCE_TYPES[@]}"; do
    # Avoid duplicate API aliases and continue if a resource type
    # cannot be listed due to API or permission restrictions.
    if ! kubectl --context="$SOURCE_CONTEXT" \
        get "$RESOURCE" -n "$NS" -o name \
        >/dev/null 2>&1; then
      continue
    fi

    COUNT=$(kubectl --context="$SOURCE_CONTEXT" \
      get "$RESOURCE" -n "$NS" -o name 2>/dev/null |
      wc -l | tr -d ' ')

    if [[ "$COUNT" -eq 0 ]]; then
      continue
    fi

    FILE="$NS_DIR/${RESOURCE//\//_}.yaml"

    echo "Exporting $RESOURCE ($COUNT objects)"

    kubectl --context="$SOURCE_CONTEXT" \
      get "$RESOURCE" -n "$NS" -o yaml |
      yq '
        del(.items[].status) |
        del(.items[].metadata.uid) |
        del(.items[].metadata.resourceVersion) |
        del(.items[].metadata.creationTimestamp) |
        del(.items[].metadata.generation) |
        del(.items[].metadata.managedFields) |
        del(.items[].metadata.ownerReferences) |
        del(.items[].metadata.annotations."kubectl.kubernetes.io/last-applied-configuration")
      ' > "$FILE"
  done

  echo "Finished namespace: $NS"
done

echo "======================================"
echo "Export completed: $OUTPUT_DIR"
echo "======================================"

