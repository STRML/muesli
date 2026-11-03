#!/usr/bin/env bash

# TelemetryDeck app identifiers are public routing identifiers, not credentials.
readonly MUESLI_TELEMETRYDECK_PRODUCTION_APP_ID="7F2B7846-1CB5-4FE6-8ABC-56F217B06A86"
readonly MUESLI_TELEMETRYDECK_DEV_APP_ID="F6448386-6643-4E85-9354-578087725FB0"
readonly MUESLI_TELEMETRYDECK_PREPROD_APP_ID="F12C21C4-3536-4DA2-98D8-40E9C26A51F8"

# Sets MUESLI_TELEMETRY_BUILD_ENV to the build_native_app.sh variables for one channel.
# The IDs above route to the upstream Muesli TelemetryDeck apps, so fork builds compile no ID
# (and the app sends no analytics) unless MUESLI_ENABLE_TELEMETRY=1 opts in.
muesli_telemetry_build_env() {
  local app_id="$1"
  local channel="$2"
  if [[ "${MUESLI_ENABLE_TELEMETRY:-0}" == "1" ]]; then
    MUESLI_TELEMETRY_BUILD_ENV=(MUESLI_TELEMETRYDECK_APP_ID="$app_id" MUESLI_TELEMETRY_CHANNEL="$channel")
  else
    MUESLI_TELEMETRY_BUILD_ENV=(MUESLI_TELEMETRYDECK_APP_ID="" MUESLI_TELEMETRY_CHANNEL="")
  fi
}
