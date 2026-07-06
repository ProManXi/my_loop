using MyLoop.Api.Entities;
using MyLoop.Api.Models;

namespace MyLoop.Api.Interfaces;

/// <summary>
/// User operations — registration, lookup, profile updates.
/// </summary>
public interface IUserService
{
    /// <summary>
    /// Creates (or returns the existing) user for the given <paramref name="firebaseUid"/>.
    /// The uid is TRUSTED — the caller (the controller) must have derived it from the validated
    /// Firebase token or minted a server-side local uid, never taken it from the request body
    /// (UsersController.Register, #99).
    /// </summary>
    Task<User> Register(RegisterRequest request, string firebaseUid, string authProvider);
    Task<User?> GetById(Guid id);
    Task<User?> GetByFirebaseUid(string firebaseUid);
    Task<User?> UpdateProfile(Guid id, UpdateUserRequest request);
    Task<UserProfileResponse?> GetRichProfile(Guid id);
    Task<bool> DeleteAccount(Guid userId);
}
