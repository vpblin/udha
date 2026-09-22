#!/bin/bash
# Desktop bridge tests, including the cross-repo contract check.
#
# The mobile decoder is compiled as its OWN module (UdhaClient) because both
# repos legitimately define SessionState / SessionPhase — putting them in one
# compilation unit collides. `-enable-testing` + `@testable import` gives the
# test access to the client's internal types without making them public.
set -e
cd "$(dirname "$0")/.."
# Point MOBILE at a checkout of the mobile app (its Bridge/ folder is the other half of the contract).
MOBILE="${MOBILE:?set MOBILE to the udha-mobile checkout}"
OUT=$(mktemp -d)

swiftc -O -enable-testing -emit-module -emit-library -static \
  -module-name UdhaClient \
  -emit-module-path "$OUT/UdhaClient.swiftmodule" \
  -o "$OUT/libUdhaClient.a" \
  "$MOBILE/Udha.ai/Bridge/AttentionEvent.swift" \
  "$MOBILE/Udha.ai/Bridge/BridgeModels.swift" \
  "$MOBILE/Udha.ai/Bridge/BridgeProtocol.swift" \
  "$MOBILE/Udha.ai/Bridge/MachineStats.swift" \
  "$MOBILE/Udha.ai/Meetings/MeetingModels.swift" \
  "$MOBILE/Udha.ai/Videos/VideoModels.swift" \
  "$MOBILE/Udha.ai/Agents/BridgeAgent.swift"

swiftc -O -I "$OUT" -L "$OUT" -lUdhaClient \
  Udha.AIDesktop/Sessions/ClaudePaneReader.swift \
  Udha.AIDesktop/Sessions/ClaudeAccountPool.swift \
  Udha.AIDesktop/Sessions/OutputClassifier.swift \
  Udha.AIDesktop/Sessions/SessionStateStore.swift \
  Udha.AIDesktop/Sessions/AttentionAgent.swift \
  Udha.AIDesktop/Sessions/ClaudeStatusSidecar.swift \
  Udha.AIDesktop/Sessions/AttentionEvent.swift \
  Udha.AIDesktop/Sessions/SessionState.swift \
  Udha.AIDesktop/Sessions/SessionFolder.swift \
  Udha.AIDesktop/Sessions/SessionPriority.swift \
  Udha.AIDesktop/Config/AppConfig.swift \
  Udha.AIDesktop/Recordings/RecordingModels.swift \
  Udha.AIDesktop/Recordings/CaptionBuilder.swift \
  Udha.AIDesktop/Sessions/SessionStatusPresentation.swift \
  Udha.AIDesktop/Sessions/SessionAttention.swift \
  Udha.AIDesktop/Sessions/SessionWireRow.swift \
  Udha.AIDesktop/Sessions/SystemStats.swift \
  Udha.AIDesktop/Sessions/SystemStatsCollector.swift \
  tests/OverlayThemeStub.swift \
  tests/LogStub.swift \
  Udha.AIDesktop/Bridge/BridgeSupport.swift \
  tests/main.swift \
  -o "$OUT/bridgetests"

"$OUT/bridgetests"
