using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace KeyStats.Helpers;

/// <summary>
/// Stores cloud sync token and user id with DPAPI (current user scope).
/// </summary>
internal static class CloudSyncCredentialStore
{
    private const string TokenFileName = "cloud_sync_token.bin";
    private const string UserIdFileName = "cloud_sync_user_id.bin";

    private static string CredentialDirectory =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "KeyStats");

    public static void SaveToken(string token) => SaveSecret(TokenFileName, token);

    public static string? LoadToken() => LoadSecret(TokenFileName);

    public static void SaveUserId(string userId) => SaveSecret(UserIdFileName, userId);

    public static string? LoadUserId() => LoadSecret(UserIdFileName);

    public static void ClearCredentials()
    {
        DeleteSecret(TokenFileName);
        DeleteSecret(UserIdFileName);
    }

    private static void SaveSecret(string fileName, string value)
    {
        var path = Path.Combine(CredentialDirectory, fileName);
        Directory.CreateDirectory(CredentialDirectory);
        var plain = Encoding.UTF8.GetBytes(value);
        var protectedBytes = ProtectedData.Protect(plain, null, DataProtectionScope.CurrentUser);
        File.WriteAllBytes(path, protectedBytes);
    }

    private static string? LoadSecret(string fileName)
    {
        var path = Path.Combine(CredentialDirectory, fileName);
        if (!File.Exists(path)) return null;

        try
        {
            var protectedBytes = File.ReadAllBytes(path);
            var plain = ProtectedData.Unprotect(protectedBytes, null, DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(plain);
        }
        catch
        {
            return null;
        }
    }

    private static void DeleteSecret(string fileName)
    {
        var path = Path.Combine(CredentialDirectory, fileName);
        if (File.Exists(path))
        {
            try { File.Delete(path); } catch { /* ignore */ }
        }
    }
}
