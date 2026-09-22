import AppKit
import SwiftUI

/// Content of the lock curtain: heavy frosted blur of whatever is behind the
/// panel, darkened, with the lock messaging centered. Carries the same state
/// story as `LockChipView` (the chip stays hidden while the curtain is up).
///
/// Honesty note baked into the design: blur hides text but window shapes and
/// colors still faintly show through — that's the style the user chose over a
/// solid black-out.
struct LockCurtainView: View {
    let manager: InputLockManager

    @State private var breathing = false

    var body: some View {
        ZStack {
            CurtainBlur()
            Color.black.opacity(0.35)

            VStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .opacity(breathing ? 1.0 : 0.55)
                    .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: breathing)
                Text(title)
                    .font(OverlayTheme.display(20))
                    .foregroundStyle(.white.opacity(0.92))
                captionView
                    .font(OverlayTheme.mono(13))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .ignoresSafeArea()
        .onAppear { breathing = true }
    }

    private var icon: String {
        switch manager.state {
        case .locked(.some): return "lock.trianglebadge.exclamationmark"
        default: return "lock.fill"
        }
    }

    private var iconColor: Color {
        switch manager.state {
        case .locked(.some): return OverlayTheme.amber
        case .authenticating(true): return OverlayTheme.stateErrored
        default: return .white.opacity(0.85)
        }
    }

    private var title: String {
        switch manager.state {
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
            Text("Press any key, then Touch ID or password")
        case .authenticating(true):
            if let deadline = manager.passthroughDeadline {
                HStack(spacing: 4) {
                    Text("re-locks in")
                    Text(timerInterval: Date()...deadline, countsDown: true)
                }
            }
        default:
            EmptyView()
        }
    }
}

/// Behind-window frosted blur — the same mechanism system HUDs use.
private struct CurtainBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .fullScreenUI
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
