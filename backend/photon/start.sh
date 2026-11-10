#!/bin/sh
# Loads Iraq on the first start (or when PHOTON_REFRESH=1), then serves
# search on port 2322.
set -eu

DATA="${PHOTON_DATA:-/photon/data}"
mkdir -p "$DATA"

if [ ! -d "$DATA/photon_data" ] || [ "${PHOTON_REFRESH:-0}" = "1" ]; then
  echo "Loading places from $PHOTON_DUMP_URL ..."
  rm -rf "$DATA/photon_data.new"
  curl -fsSL "$PHOTON_DUMP_URL" \
    | zstd --stdout -d \
    | jq -c -f /photon/prepare.jq \
    | java $JAVA_OPTS -jar /photon/photon.jar import \
        -import-file - \
        -languages "$PHOTON_LANGUAGES" \
        -data-dir "$DATA/photon_data.new"
  # Swap only when the import finished, so a failed refresh keeps the old data.
  rm -rf "$DATA/photon_data"
  mv "$DATA/photon_data.new/photon_data" "$DATA/photon_data" 2>/dev/null \
    || mv "$DATA/photon_data.new" "$DATA/photon_data"
  rm -rf "$DATA/photon_data.new"
  echo "Places loaded."
fi

exec java $JAVA_OPTS -jar /photon/photon.jar serve \
  -data-dir "$DATA" \
  -languages "$PHOTON_LANGUAGES" \
  -listen-ip 0.0.0.0 \
  -listen-port 2322
