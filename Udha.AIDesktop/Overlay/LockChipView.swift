import SwiftUI

/// The discreet 🔒 badge shown while the input lock is engaged. Breathes so it
/// reads as live rather than a stale screenshot, and states exactly what is and
/// isn't dead — a chip that overstates the lock is the failure mode to avoid.
struct LockChipView: View {
    let manager: InputLockManager

    @State private var breathing = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(iconColor)
                .opacity(breathing ? 1.0 : 0.55)
                .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: breathing)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(OverlayTheme.mono(11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                captionView
                    .font(OverlayTheme.mono(9))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(OverlayTheme.panelBG.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(OverlayTheme.hairlineStrong, lineWidth: 1)
                )
        )
        .onAppear { breathing = true }
    }

    private var icon: String {
        switch manager.state {
        case .failed: return "lock.open.trianglebadge.exclamationmark"
        case .locked(.some): return "lock.trianglebadge.exclamationmark"
        default: return "lock.fill"
        }
    }

    private var iconColor: Color {
        switch manager.state {
        case .failed: return OverlayTheme.stateErrored
        case .locked(.some): return OverlayTheme.amber
        case .authenticating(true): return OverlayTheme.stateErrored
        default: return .white.opacity(0.85)
        }
    }

    private var title: String {
        switch manager.state {
        case .failed: return "Lock failed — input is live"
        case .authenticating(true): return "Keyboard released for password"
        case .authenticating(false): return "Waiting for Touch ID…"
        case .locked(.some): return "Mouse locked — keyboard is live"
        default: return "Input locked"
        }
    }

    @ViewBuilder
    private var captionView: some View {
        switch manager.state {
        case .locked(.secureInputKeyboardLive(let app)):
            Text("\(app ?? "An app") has Secure Keyboard Entry on")
        case .locked(nil):
            Text("Touch ID or password to unlock")
        case .authenticating(true):
            if let deadline = manager.passthroughDeadline {
                // Live self-updating countdown — no timer needed.
                HStack(spacing: 3) {
                    Text("re-locks in")
                    Text(timerInterval: Date()...deadline, countsDown: true)
                }
            }
        case .failed(let f):
            Text(f.message)
        default:
            EmptyView()
        }
    }
}
