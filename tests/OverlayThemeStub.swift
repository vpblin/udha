import SwiftUI

/// Colour stand-in for the real `OverlayTheme`, which transitively needs the
/// whole configuration graph (`OverlayEdge` and friends) to compile.
///
/// These tests are about the *logic* in `SessionStatusPresentation` — the
/// attention grouping, the stale threshold, the wire row — none of which
/// depends on the actual colour values. Stubbing keeps the test's compile
/// surface to the model layer instead of dragging in app configuration.
enum OverlayTheme {
    static let amber = Color.orange
    static let stateCompleted = Color.gray
    static let stateErrored = Color.red
    static let stateIdle = Color.gray
    static let stateNeedsInput = Color.orange
    static let statePlanning = Color.purple
    static let stateReady = Color.green
    static let stateStale = Color.gray
    static let stateWorking = Color.blue
}
