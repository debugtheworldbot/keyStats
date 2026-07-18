using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using KeyStats.Models;

namespace KeyStats.Services;

public interface ISyncTransport : IDisposable
{
    Task<CreateVaultResponse> CreateVaultAsync(CreateVaultRequest request, CancellationToken cancellationToken);
    Task<RecoverVaultResponse> RecoverVaultAsync(RecoverVaultRequest request, CancellationToken cancellationToken);
    Task<CreatePairingSessionResponse> CreatePairingSessionAsync(CreatePairingSessionRequest request, CancellationToken cancellationToken);
    Task<JoinPairingSessionResponse> JoinPairingSessionAsync(string code, JoinPairingSessionRequest request, string deviceToken, CancellationToken cancellationToken);
    Task ApprovePairingSessionAsync(string sessionId, ApprovePairingSessionRequest request, string deviceToken, CancellationToken cancellationToken);
    Task<CompletePairingSessionResponse> CompletePairingSessionAsync(string sessionId, CompletePairingSessionRequest request, CancellationToken cancellationToken);
    Task<SyncResponse> SyncAsync(SyncRequest request, string deviceToken, string idempotencyKey, CancellationToken cancellationToken);
    Task<SyncStateResponse> GetStateAsync(string deviceToken, CancellationToken cancellationToken);
    Task<HistoryResponse> GetHistoryAsync(long cursor, string deviceToken, CancellationToken cancellationToken);
    Task RevokeDeviceAsync(string deviceId, string deviceToken, CancellationToken cancellationToken);
    Task DeleteVaultAsync(string deviceToken, CancellationToken cancellationToken);
}

public sealed class CloudflareSyncTransport : ISyncTransport
{
    // A history page can contain 100 maximum-size encrypted records plus the
    // small device/current manifest returned by /sync. Keep a bounded response
    // while allowing the protocol's documented worst-case page.
    private const int MaximumResponseBytes = 16 * 1024 * 1024;
    private const string VaultsPath = "v1/vaults";
    private const string VaultPath = "v1/vault";
    private const string RecoverPath = "v1/recover";
    private const string PairingSessionsPath = "v1/pairing-sessions";
    private const string SyncPath = "v1/sync";
    private const string StatePath = "v1/state";
    private const string HistoryPath = "v1/history";
    private const string DevicesPath = "v1/devices";
    private readonly HttpClient _client;
    private readonly JsonSerializerOptions _jsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true
    };

    public CloudflareSyncTransport(Uri baseUri, HttpMessageHandler? handler = null)
    {
        if (!string.Equals(baseUri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) ||
            string.IsNullOrWhiteSpace(baseUri.Host))
        {
            throw new ArgumentException("Sync service base URL must use HTTPS.", nameof(baseUri));
        }
        _client = handler == null ? new HttpClient() : new HttpClient(handler, disposeHandler: true);
        _client.BaseAddress = baseUri;
        _client.Timeout = TimeSpan.FromSeconds(30);
        _client.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        _client.DefaultRequestHeaders.UserAgent.ParseAdd("KeyStats-Windows/1");
    }

    public Task<CreateVaultResponse> CreateVaultAsync(CreateVaultRequest request, CancellationToken cancellationToken)
        => SendAsync<CreateVaultRequest, CreateVaultResponse>(HttpMethod.Post, VaultsPath, request, null, cancellationToken);

    public Task<RecoverVaultResponse> RecoverVaultAsync(RecoverVaultRequest request, CancellationToken cancellationToken)
        => SendAsync<RecoverVaultRequest, RecoverVaultResponse>(HttpMethod.Post, RecoverPath, request, null, cancellationToken);

    public Task<CreatePairingSessionResponse> CreatePairingSessionAsync(
        CreatePairingSessionRequest request,
        CancellationToken cancellationToken)
        => SendAsync<CreatePairingSessionRequest, CreatePairingSessionResponse>(
            HttpMethod.Post,
            PairingSessionsPath,
            request,
            null,
            cancellationToken);

    public Task<JoinPairingSessionResponse> JoinPairingSessionAsync(
        string code,
        JoinPairingSessionRequest request,
        string deviceToken,
        CancellationToken cancellationToken)
        => SendAsync<JoinPairingSessionRequest, JoinPairingSessionResponse>(
            HttpMethod.Post,
            PairingSessionsPath + "/" + Uri.EscapeDataString(code) + "/join",
            request,
            deviceToken,
            cancellationToken);

    public Task ApprovePairingSessionAsync(
        string sessionId,
        ApprovePairingSessionRequest request,
        string deviceToken,
        CancellationToken cancellationToken)
        => SendWithoutResponseAsync(
            HttpMethod.Post,
            PairingSessionsPath + "/" + Uri.EscapeDataString(sessionId) + "/approve",
            request,
            deviceToken,
            cancellationToken);

    public Task<CompletePairingSessionResponse> CompletePairingSessionAsync(
        string sessionId,
        CompletePairingSessionRequest request,
        CancellationToken cancellationToken)
        => SendAsync<CompletePairingSessionRequest, CompletePairingSessionResponse>(
            HttpMethod.Post,
            PairingSessionsPath + "/" + Uri.EscapeDataString(sessionId) + "/complete",
            request,
            null,
            cancellationToken);

    public Task<SyncResponse> SyncAsync(
        SyncRequest request,
        string deviceToken,
        string idempotencyKey,
        CancellationToken cancellationToken)
    {
        if (request == null) throw new ArgumentNullException(nameof(request));
        if (request.Archives == null || request.Archives.Count > SyncProtocol.MaximumArchivesPerRequest)
        {
            throw new ArgumentException(
                $"A sync request can contain at most {SyncProtocol.MaximumArchivesPerRequest} archives.",
                nameof(request));
        }
        if (!request.BootstrapComplete && !SyncBatchPlanner.IsBootstrapReason(request.Reason))
        {
            throw new ArgumentException(
                "Only bootstrap, recovery, and pairing requests can be marked incomplete.",
                nameof(request));
        }

        return SendAsync<SyncRequest, SyncResponse>(
            HttpMethod.Post,
            SyncPath,
            request,
            deviceToken,
            cancellationToken,
            new Dictionary<string, string> { ["Idempotency-Key"] = idempotencyKey });
    }

    public Task<HistoryResponse> GetHistoryAsync(long cursor, string deviceToken, CancellationToken cancellationToken)
    {
        var path = HistoryPath + "?cursor=" + Math.Max(0, cursor).ToString(CultureInfo.InvariantCulture);
        return SendAsync<object?, HistoryResponse>(HttpMethod.Get, path, null, deviceToken, cancellationToken);
    }

    public Task<SyncStateResponse> GetStateAsync(string deviceToken, CancellationToken cancellationToken)
        => SendAsync<object?, SyncStateResponse>(HttpMethod.Get, StatePath, null, deviceToken, cancellationToken);

    public Task RevokeDeviceAsync(string deviceId, string deviceToken, CancellationToken cancellationToken)
        => SendWithoutResponseAsync<object?>(
            HttpMethod.Delete,
            DevicesPath + "/" + Uri.EscapeDataString(deviceId),
            null,
            deviceToken,
            cancellationToken);

    public Task DeleteVaultAsync(string deviceToken, CancellationToken cancellationToken)
        => SendWithoutResponseAsync<object?>(HttpMethod.Delete, VaultPath, null, deviceToken, cancellationToken);

    public void Dispose() => _client.Dispose();

    private async Task<TResponse> SendAsync<TRequest, TResponse>(
        HttpMethod method,
        string path,
        TRequest requestBody,
        string? bearerToken,
        CancellationToken cancellationToken,
        IReadOnlyDictionary<string, string>? extraHeaders = null)
    {
        using var request = CreateRequest(method, path, requestBody, bearerToken, extraHeaders);
        using var response = await _client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken)
            .ConfigureAwait(false);
        var responseBytes = await ReadResponseBytesAsync(response, cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            throw CreateException(response, responseBytes);
        }

        if (responseBytes.Length == 0)
        {
            throw new SyncTransportException(response.StatusCode, "Sync service returned an empty response.", null);
        }

        try
        {
            return JsonSerializer.Deserialize<TResponse>(responseBytes, _jsonOptions)
                   ?? throw new JsonException("Response was null.");
        }
        catch (JsonException ex)
        {
            throw new SyncTransportException(response.StatusCode, "Sync service returned invalid JSON.", null, ex);
        }
    }

    private async Task SendWithoutResponseAsync<TRequest>(
        HttpMethod method,
        string path,
        TRequest requestBody,
        string? bearerToken,
        CancellationToken cancellationToken)
    {
        using var request = CreateRequest(method, path, requestBody, bearerToken);
        using var response = await _client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken)
            .ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            var responseBytes = await ReadResponseBytesAsync(response, cancellationToken).ConfigureAwait(false);
            throw CreateException(response, responseBytes);
        }
    }

    private HttpRequestMessage CreateRequest<TRequest>(
        HttpMethod method,
        string path,
        TRequest body,
        string? bearerToken,
        IReadOnlyDictionary<string, string>? extraHeaders = null)
    {
        var request = new HttpRequestMessage(method, path);
        if (!string.IsNullOrWhiteSpace(bearerToken))
        {
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", bearerToken);
        }

        if (extraHeaders != null)
        {
            foreach (var header in extraHeaders)
            {
                request.Headers.TryAddWithoutValidation(header.Key, header.Value);
            }
        }

        if (body != null)
        {
            var json = JsonSerializer.Serialize(body, _jsonOptions);
            request.Content = new StringContent(json, Encoding.UTF8, "application/json");
        }
        return request;
    }

    private static SyncTransportException CreateException(HttpResponseMessage response, byte[] responseBytes)
    {
        TimeSpan? retryAfter = null;
        if (response.Headers.RetryAfter?.Delta is TimeSpan delta)
        {
            retryAfter = delta;
        }
        else if (response.Headers.RetryAfter?.Date is DateTimeOffset retryDate)
        {
            var delay = retryDate - DateTimeOffset.UtcNow;
            retryAfter = delay > TimeSpan.Zero ? delay : TimeSpan.Zero;
        }
        else if (response.Headers.TryGetValues("Retry-After", out var values))
        {
            foreach (var value in values)
            {
                if (int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var seconds))
                {
                    retryAfter = TimeSpan.FromSeconds(Math.Max(0, seconds));
                    break;
                }
            }
        }

        ReadSafeErrorDetails(
            responseBytes,
            out var code,
            out var activeDeviceCount,
            out var vaultId,
            out var devices);
        var message = string.IsNullOrWhiteSpace(code)
            ? $"Sync service request failed ({(int)response.StatusCode})."
            : $"Sync service request failed ({(int)response.StatusCode}, {code}).";
        return new SyncTransportException(
            response.StatusCode,
            message,
            retryAfter,
            errorCode: code,
            activeDeviceCount: activeDeviceCount,
            vaultId: vaultId,
            devices: devices);
    }

    private static async Task<byte[]> ReadResponseBytesAsync(
        HttpResponseMessage response,
        CancellationToken cancellationToken)
    {
        if (response.Content.Headers.ContentLength is long contentLength && contentLength > MaximumResponseBytes)
        {
            throw new SyncTransportException(response.StatusCode, "Sync service response exceeded the size limit.", null);
        }

        using var input = await response.Content.ReadAsStreamAsync().ConfigureAwait(false);
        using var output = new MemoryStream();
        var buffer = new byte[8192];
        while (true)
        {
            var read = await input.ReadAsync(buffer, 0, buffer.Length, cancellationToken).ConfigureAwait(false);
            if (read == 0) break;
            if (output.Length + read > MaximumResponseBytes)
            {
                throw new SyncTransportException(response.StatusCode, "Sync service response exceeded the size limit.", null);
            }
            output.Write(buffer, 0, read);
        }
        return output.ToArray();
    }

    private static void ReadSafeErrorDetails(
        byte[] responseBytes,
        out string? code,
        out int? activeDeviceCount,
        out string? vaultId,
        out IReadOnlyList<DeviceSummary> devices)
    {
        code = null;
        activeDeviceCount = null;
        vaultId = null;
        devices = Array.Empty<DeviceSummary>();
        if (responseBytes.Length == 0 || responseBytes.Length > 64 * 1024) return;
        try
        {
            using var document = JsonDocument.Parse(responseBytes);
            if (!document.RootElement.TryGetProperty("code", out var codeElement) ||
                codeElement.ValueKind != JsonValueKind.String)
            {
                return;
            }

            var candidateCode = codeElement.GetString();
            if (candidateCode == null || string.IsNullOrWhiteSpace(candidateCode) || candidateCode.Length > 64) return;
            foreach (var character in candidateCode)
            {
                if (!(char.IsLetterOrDigit(character) || character == '_' || character == '-')) return;
            }
            code = candidateCode;

            if (document.RootElement.TryGetProperty("activeDeviceCount", out var countElement) &&
                countElement.ValueKind == JsonValueKind.Number &&
                countElement.TryGetInt32(out var count) &&
                count >= 1 && count <= SyncProtocol.MaximumDevices)
            {
                activeDeviceCount = count;
            }

            if (document.RootElement.TryGetProperty("vaultId", out var vaultElement) &&
                vaultElement.ValueKind == JsonValueKind.String)
            {
                var candidateVaultId = vaultElement.GetString();
                if (Guid.TryParse(candidateVaultId, out _)) vaultId = candidateVaultId;
            }

            if (document.RootElement.TryGetProperty("devices", out var devicesElement) &&
                devicesElement.ValueKind == JsonValueKind.Array &&
                devicesElement.GetArrayLength() <= SyncProtocol.MaximumDevices)
            {
                var parsedDevices = JsonSerializer.Deserialize<List<DeviceSummary>>(
                    devicesElement.GetRawText(),
                    new JsonSerializerOptions
                    {
                        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
                        PropertyNameCaseInsensitive = true
                    });
                if (parsedDevices != null && parsedDevices.All(device =>
                        Guid.TryParse(device.DeviceId, out _)))
                {
                    devices = parsedDevices;
                }
            }
        }
        catch (JsonException)
        {
        }
    }
}

public sealed class SyncTransportException : Exception
{
    public HttpStatusCode StatusCode { get; }
    public TimeSpan? RetryAfter { get; }
    public string? ErrorCode { get; }
    public int? ActiveDeviceCount { get; }
    public string? VaultId { get; }
    public IReadOnlyList<DeviceSummary> Devices { get; }

    public SyncTransportException(
        HttpStatusCode statusCode,
        string message,
        TimeSpan? retryAfter,
        Exception? innerException = null,
        string? errorCode = null,
        int? activeDeviceCount = null,
        string? vaultId = null,
        IReadOnlyList<DeviceSummary>? devices = null)
        : base(message, innerException)
    {
        StatusCode = statusCode;
        RetryAfter = retryAfter;
        ErrorCode = errorCode;
        ActiveDeviceCount = activeDeviceCount;
        VaultId = vaultId;
        Devices = devices ?? Array.Empty<DeviceSummary>();
    }
}
