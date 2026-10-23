import SwiftUI

enum StreamStatusTone {
    case loading
    case waiting
    case attention
    case warning
    case error
}

struct StreamStatusSurface: View {
    let game: GameInfo
    let title: String
    let message: String?
    var tone: StreamStatusTone = .loading
    var detail: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var cancelAction: (() -> Void)? = nil
    @FocusState private var isActionFocused: Bool

    var body: some View {
        ZStack {
            StreamStartupBackground(game: game)

            VStack(spacing: 18) {
                statusIcon
                    .frame(height: 54)

                Text(game.title)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .shadow(radius: 8)

                Text(title)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white.opacity(0.78))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 760)

                if let message, !message.isEmpty {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.48))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 760)
                }

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.36))
                        .multilineTextAlignment(.center)
                        .padding(.top, 16)
                }

                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(AppActionButtonStyle(tone: .primary, minWidth: 220))
                        .focused($isActionFocused)
                        .defaultFocus($isActionFocused, true)
                        .padding(.top, 4)
                }
            }
            .padding(80)
            .background {
                LinearGradient(
                    colors: [
                        .clear,
                        .black.opacity(0.30),
                        .black.opacity(0.22),
                        .clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .blur(radius: 22)
                .padding(.horizontal, -120)
                .padding(.vertical, -56)
            }
        }
        .onAppear {
            guard actionTitle != nil else { return }
            DispatchQueue.main.async {
                isActionFocused = true
            }
        }
        .onChange(of: actionTitle) { _, newValue in
            guard newValue != nil else { return }
            DispatchQueue.main.async {
                isActionFocused = true
            }
        }
        .task(id: actionTitle) {
            guard let action else { return }
            await LaunchScreenControllerInput.monitor(
                onConfirm: action,
                onCancel: cancelAction ?? action
            )
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch tone {
        case .loading, .waiting:
            ProgressView()
                .scaleEffect(1.3)
                .tint(.white)
        case .attention:
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.yellow)
        case .warning:
            Image(systemName: "wifi.slash")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.yellow)
        case .error:
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.orange)
        }
    }
}
