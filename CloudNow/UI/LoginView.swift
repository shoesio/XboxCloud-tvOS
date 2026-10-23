import SwiftUI

/// Shared sign-in surface for the direct-launch game apps.
struct LoginView: View {
    @Environment(XCloudAuthManager.self) private var xcloudAuth

    var body: some View {
        ZStack {
            FortniteStartupArtwork()
            xboxSignInView
        }
        .task { if xcloudAuth.phase == .signedOut { xcloudAuth.signIn() } }
        .onPlayPauseCommand {
            if case .failed = xcloudAuth.phase { xcloudAuth.signIn() }
        }
    }

    @ViewBuilder
    private var xboxSignInView: some View {
        switch xcloudAuth.phase {
        case .signedIn:
            EmptyView()
        case .signedOut:
            EmptyView()
        case .requestingCode, .exchangingTokens:
            EmptyView()
        case .waitingForUser(let code):
            ProviderQRCodeSignInView(
                title: "Connect Xbox Cloud Gaming",
                systemImage: "xbox.logo",
                tint: .green,
                qrValue: code.directURL ?? code.verificationURL,
                instruction: "Scan with your phone, then complete Microsoft sign-in.",
                code: code.code,
                status: "Waiting for sign in…"
            )
            .background(.black.opacity(0.94))
        case .failed(let message):
            VStack {
                Spacer()
                VStack(spacing: 12) {
                    Text("Let’s get you signed in")
                        .font(.headline)
                    Text(message)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Play/Pause to try again · Back to go Home")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                }
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 760)
                .padding(28)
                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 60)
                .padding(.bottom, 60)
            }
        }
    }
}
