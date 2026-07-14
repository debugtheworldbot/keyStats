using System;
using System.Linq;
using System.Reflection;

namespace KeyStats.Services;

public static class SyncServiceConfiguration
{
    public static string ConfiguredBaseUrl
    {
        get
        {
            var value = typeof(SyncServiceConfiguration).Assembly
                .GetCustomAttributes<AssemblyMetadataAttribute>()
                .FirstOrDefault(attribute => string.Equals(
                    attribute.Key,
                    "SyncServiceBaseUrl",
                    StringComparison.Ordinal))
                ?.Value;

            return Normalize(value);
        }
    }

    public static bool TryCreateBaseUri(out Uri? baseUri)
    {
        var candidate = ConfiguredBaseUrl;

        if (!Uri.TryCreate(candidate, UriKind.Absolute, out var parsed) ||
            !string.Equals(parsed.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) ||
            string.IsNullOrWhiteSpace(parsed.Host) ||
            !parsed.Host.EndsWith(".workers.dev", StringComparison.OrdinalIgnoreCase) ||
            !string.IsNullOrEmpty(parsed.UserInfo) ||
            !string.IsNullOrEmpty(parsed.Query) ||
            !string.IsNullOrEmpty(parsed.Fragment) ||
            candidate.IndexOf('<') >= 0 ||
            candidate.IndexOf("example", StringComparison.OrdinalIgnoreCase) >= 0)
        {
            baseUri = null;
            return false;
        }

        baseUri = new Uri(parsed.AbsoluteUri.TrimEnd('/') + "/", UriKind.Absolute);
        return true;
    }

    private static string Normalize(string? value)
    {
        var normalized = (value ?? string.Empty).Trim();
        if (string.Equals(normalized, "$(SyncServiceBaseUrl)", StringComparison.Ordinal) ||
            normalized.IndexOf("REPLACE_ME", StringComparison.OrdinalIgnoreCase) >= 0)
        {
            return string.Empty;
        }

        return normalized;
    }
}
