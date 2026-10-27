import SwiftUI

struct FirstRunView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var config: ConfigStore
    let keychain: KeychainStore
    var onComplete: () -> Void

    @State private var step: Int = 0
    @State private var elevenLabsKey: String = ""
    @State private var errorMessage: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to Udha.AI").font(.title).bold()
            Text("Two-minute setup. Everything gets saved locally in Keychain.").font(.callout).foregroundStyle(.secondary)

            switch step {
            case 0: elevenLabsStep
            default: doneStep
            }

            if !errorMessage.isEmpty {
                Text(errorMessage).foregroundStyle(.red).font(.caption)
            }

            HStack {
                Spacer()
                if step < 1 {
                    Button("Finish") { advance() }
                        .keyboardShortcut(.return)
                        .disabled(nextDisabled)
                } else {
                    Button("Done") { onComplete(); dismiss() }
                        .keyboardShortcut(.return)
                }
            }
        }
        .padding(24)
        .frame(width: 520, height: 380)
    }

    private var elevenLabsStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ElevenLabs key").font(.headline)
            Text("For meeting transcription, when not using a local Whisper server.")
                .font(.caption).foregroundStyle(.secondary)
            SecureField("sk_…", text: $elevenLabsKey)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("You're set.").font(.headline)
            Text("Add your first session from the main window.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var nextDisabled: Bool {
        step == 0 ? elevenLabsKey.isEmpty : false
    }

    private func advance() {
        errorMessage = ""
        switch step {
        case 0:
            try? keychain.set(elevenLabsKey, for: .elevenLabsAPIKey)
            config.mutate { cfg in
                cfg.hasCompletedFirstRun = true
            }
            step = 1
        default:
            break
        }
    }
}
