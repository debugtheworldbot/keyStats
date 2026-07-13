using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using KeyStats.Models;

namespace KeyStats.Services;

internal sealed class CloudSyncClient
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true
    };

    private readonly HttpClient _http;

    public CloudSyncClient(HttpClient? httpClient = null)
    {
        _http = httpClient ?? new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
    }

    public Task<CloudAuthResponse> RegisterAsync(Uri baseUrl, string username, string password, CancellationToken ct = default) =>
        AuthRequestAsync(baseUrl, "auth/register", username, password, ct);

    public Task<CloudAuthResponse> LoginAsync(Uri baseUrl, string username, string password, CancellationToken ct = default) =>
        AuthRequestAsync(baseUrl, "auth/login", username, password, ct);

    public async Task<List<CloudDevice>> ListDevicesAsync(Uri baseUrl, string token, CancellationToken ct = default)
    {
        var response = await RequestAsync<CloudDevicesResponse>(baseUrl, "devices", HttpMethod.Get, token, null, null, ct);
        return response.Devices ?? new List<CloudDevice>();
    }

    public Task<CloudDevice> RegisterDeviceAsync(Uri baseUrl, string token, CloudRegisterDeviceRequest body, CancellationToken ct = default) =>
        RequestAsync<CloudDevice>(baseUrl, "devices", HttpMethod.Post, token, body, null, ct);

    public Task UpsertStatsAsync(Uri baseUrl, string token, CloudUpsertStatsRequest body, CancellationToken ct = default) =>
        RequestAsync<object>(baseUrl, "sync/stats", HttpMethod.Put, token, body, null, ct);

    public Task BulkUpsertStatsAsync(Uri baseUrl, string token, CloudBulkUpsertStatsRequest body, CancellationToken ct = default) =>
        RequestAsync<object>(baseUrl, "sync/stats/bulk", HttpMethod.Post, token, body, null, ct);

    public async Task<List<CloudStatsRecord>> ListStatsAsync(
        Uri baseUrl,
        string token,
        string? from,
        string? to,
        string? deviceId,
        CancellationToken ct = default)
    {
        var query = new List<string>();
        if (!string.IsNullOrWhiteSpace(from)) query.Add($"from={Uri.EscapeDataString(from)}");
        if (!string.IsNullOrWhiteSpace(to)) query.Add($"to={Uri.EscapeDataString(to)}");
        if (!string.IsNullOrWhiteSpace(deviceId)) query.Add($"device_id={Uri.EscapeDataString(deviceId)}");
        var queryString = query.Count > 0 ? "?" + string.Join("&", query) : null;

        var response = await RequestAsync<CloudStatsListResponse>(
            baseUrl, "sync/stats", HttpMethod.Get, token, null, queryString, ct);
        return response.Records ?? new List<CloudStatsRecord>();
    }

    private Task<CloudAuthResponse> AuthRequestAsync(
        Uri baseUrl,
        string path,
        string username,
        string password,
        CancellationToken ct)
    {
        var body = new CloudAuthRequest { Username = username, Password = password };
        return RequestAsync<CloudAuthResponse>(baseUrl, path, HttpMethod.Post, null, body, null, ct);
    }

    private async Task<T> RequestAsync<T>(
        Uri baseUrl,
        string path,
        HttpMethod method,
        string? token,
        object? body,
        string? queryString,
        CancellationToken ct)
    {
        var url = BuildApiUrl(baseUrl, path, queryString);
        using var request = new HttpRequestMessage(method, url);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        if (!string.IsNullOrWhiteSpace(token))
        {
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        }

        if (body != null)
        {
            var json = JsonSerializer.Serialize(body, JsonOptions);
            request.Content = new StringContent(json, Encoding.UTF8, "application/json");
        }

        HttpResponseMessage response;
        try
        {
            response = await _http.SendAsync(request, ct).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            throw new CloudSyncException(ex.Message);
        }

        using (response)
        {
            var data = await response.Content.ReadAsByteArrayAsync().ConfigureAwait(false);
            if (response.IsSuccessStatusCode)
            {
                if (data.Length == 0)
                {
                    if (typeof(T) == typeof(object))
                    {
                        return default!;
                    }

                    data = Encoding.UTF8.GetBytes("{}");
                }

                try
                {
                    var result = JsonSerializer.Deserialize<T>(data, JsonOptions);
                    if (result == null)
                    {
                        throw new CloudSyncException(Properties.Strings.Sync_Error_InvalidResponse);
                    }

                    return result;
                }
                catch (JsonException)
                {
                    throw new CloudSyncException(Properties.Strings.Sync_Error_InvalidResponse);
                }
            }

            if (data.Length > 0)
            {
                try
                {
                    var apiError = JsonSerializer.Deserialize<CloudAPIErrorResponse>(data, JsonOptions);
                    if (!string.IsNullOrWhiteSpace(apiError?.Error))
                    {
                        throw new CloudSyncException(apiError.Error);
                    }
                }
                catch (JsonException)
                {
                    // fall through
                }
            }

            throw new CloudSyncException($"HTTP {(int)response.StatusCode}");
        }
    }

    private static Uri BuildApiUrl(Uri baseUrl, string path, string? queryString)
    {
        var basePath = baseUrl.AbsolutePath.TrimEnd('/');
        var fullPath = $"{basePath}/api/v1/{path}";
        var builder = new UriBuilder(baseUrl.Scheme, baseUrl.Host, baseUrl.Port, fullPath);
        if (!string.IsNullOrWhiteSpace(queryString))
        {
            builder.Query = queryString.TrimStart('?');
        }

        return builder.Uri;
    }
}
