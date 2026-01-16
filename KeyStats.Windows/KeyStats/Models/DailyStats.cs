using System.Text.Json.Serialization;

namespace KeyStats.Models;

public class DailyStats
{
    private const double MetersPerPixel = 0.000264583;

    [JsonPropertyName("date")]
    public DateTime Date { get; set; }

    [JsonPropertyName("keyPresses")]
    public int KeyPresses { get; set; }

    [JsonPropertyName("keyPressCounts")]
    public Dictionary<string, int> KeyPressCounts { get; set; } = new();

    [JsonPropertyName("leftClicks")]
    public int LeftClicks { get; set; }

    [JsonPropertyName("rightClicks")]
    public int RightClicks { get; set; }

    [JsonPropertyName("mouseDistance")]
    public double MouseDistance { get; set; }

    [JsonPropertyName("scrollDistance")]
    public double ScrollDistance { get; set; }

    [JsonIgnore]
    public int TotalClicks => LeftClicks + RightClicks;

    public DailyStats()
    {
        Date = DateTime.Today;
    }

    public DailyStats(DateTime date)
    {
        Date = date.Date;
    }

    public string FormattedMouseDistance
    {
        get
        {
            var meters = MouseDistance * MetersPerPixel;
            if (meters >= 1000)
            {
                return $"{meters / 1000:F2} km";
            }
            else if (MouseDistance >= 1000)
            {
                return $"{meters:F1} m";
            }
            return $"{MouseDistance:F0} px";
        }
    }

    public string FormattedScrollDistance
    {
        get
        {
            if (ScrollDistance >= 10000)
            {
                return $"{ScrollDistance / 1000:F1} k";
            }
            return $"{ScrollDistance:F0} px";
        }
    }
}
