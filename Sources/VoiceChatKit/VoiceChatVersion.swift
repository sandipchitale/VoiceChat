import Foundation

/// Reported by every `Server` instance, over every transport, so a host can
/// never see the stdio and HTTP paths disagree about what's running.
public enum VoiceChatVersion {
    public static let string = "0.0.3"
}
