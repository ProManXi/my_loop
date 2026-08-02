using FirebaseAdmin.Messaging;
using MyLoop.Api.Interfaces;

namespace MyLoop.Api.Services;

/// <summary>
/// Real <see cref="IFcmSender"/> backed by the Firebase Admin SDK. Registered only when
/// <c>Push:Enabled</c> is true and a service-account credential is configured (see
/// <c>ServiceRegistrationExtensions.AddMyLoopPushNotifications</c>) — everywhere else,
/// <see cref="LoggingFcmSender"/> keeps the app running without live credentials.
/// </summary>
public class FirebaseFcmSender : IFcmSender
{
    public async Task<IReadOnlyList<FcmSendOutcome>> SendEachAsync(IReadOnlyList<string> tokens, string title, string body)
    {
        var messages = tokens
            .Select(token => new Message
            {
                // The mobile client registers classic FCM registration tokens (RegisterDeviceToken),
                // not Firebase Installation IDs, so Token is the correct field despite the SDK
                // deprecating it in favor of Fid for newer integrations.
#pragma warning disable CS0618
                Token = token,
#pragma warning restore CS0618
                Notification = new Notification { Title = title, Body = body },
            })
            .ToList();

        var response = await FirebaseMessaging.DefaultInstance.SendEachAsync(messages);

        var outcomes = new List<FcmSendOutcome>(tokens.Count);
        for (var i = 0; i < tokens.Count; i++)
        {
            var result = response.Responses[i];
            var isUnregistered = !result.IsSuccess
                && result.Exception?.MessagingErrorCode == MessagingErrorCode.Unregistered;
            outcomes.Add(new FcmSendOutcome(tokens[i], result.IsSuccess, isUnregistered));
        }

        return outcomes;
    }
}
