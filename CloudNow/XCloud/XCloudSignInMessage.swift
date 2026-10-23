import Foundation

/// User-facing copy only. Never pass service response bodies through to the TV.
enum XCloudSignInMessage {
    static func message(for error: Error) -> String {
        if let xbox = error as? XCloudError {
            switch xbox {
            case .server(let status, let body):
                if let data = body.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let code = (json["XErr"] as? NSNumber)?.stringValue ?? json["XErr"] as? String
                    if code == "2148916233" {
                        return "This Microsoft account doesn’t have an Xbox profile yet. Try your usual Xbox account, or visit xbox.com on your phone to finish setting one up."
                    }
                }
                if status == 429 || status >= 500 {
                    return "Xbox is having trouble signing you in right now. Please try again in a little while."
                }
                return "We couldn’t sign you in to Xbox. Try again with the Microsoft account you use for gaming."
            case .authorizationExpired:
                return "Your sign-in code has expired. Try again to get a new code."
            case .notSignedIn, .authorizationPending:
                return "Please sign in with the Microsoft account you use for Xbox."
            case .timedOut:
                return "Signing in took too long. Check your connection and try again."
            case .invalidResponse:
                return "We couldn’t complete your Xbox sign-in. Please try again."
            }
        }
        if (error as NSError).domain == NSURLErrorDomain {
            return "We couldn’t reach Xbox. Check your internet connection and try again."
        }
        return "We couldn’t complete your Xbox sign-in. Please try again."
    }
}
