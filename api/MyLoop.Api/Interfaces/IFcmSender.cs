namespace MyLoop.Api.Interfaces;

/// <summary>
/// The outcome of sending one FCM message to one device token.
/// </summary>
/// <param name="Token">The device token the message was addressed to.</param>
/// <param name="Success">Whether FCM accepted the message for delivery.</param>
/// <param name="IsUnregistered">
/// True when FCM reports the token itself is no longer valid (app uninstalled, token
/// rotated). The caller should stop sending to it and delete it from storage.
/// </param>
public sealed record FcmSendOutcome(string Token, bool Success, bool IsUnregistered);

/// <summary>
/// Thin seam over the Firebase Cloud Messaging SDK. Exists so <c>PushNotificationService</c>
/// can be unit-tested (including the dead-token pruning path) without live Firebase
/// credentials — the SDK's own <c>FirebaseMessaging</c> type is not mockable directly.
/// </summary>
public interface IFcmSender
{
    /// <summary>
    /// Sends the same notification to every token in one batched call.
    /// </summary>
    Task<IReadOnlyList<FcmSendOutcome>> SendEachAsync(IReadOnlyList<string> tokens, string title, string body);
}
