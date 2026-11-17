using System.Text.Json;
using System.Text.Json.Serialization;

namespace TPClassroom.Core;

/// <summary>Network ports (see PROTOCOL.md).</summary>
static class Ports
{
    public const int Tcp = 52800;
    public const int Udp = 52801;
}

/// <summary>Modifier bits used in InputEvent.Mods.</summary>
static class Mods
{
    public const int Shift = 1;
    public const int Control = 2;
    public const int Alt = 4;
    public const int Meta = 8;
    public const int CapsLock = 16;
}

static class Json
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        PropertyNameCaseInsensitive = true,
    };
}

/// <summary>Mouse and keyboard input from the teacher's live view.</summary>
sealed class InputEvent
{
    public string Kind { get; set; } = "";
    public double? X { get; set; }
    public double? Y { get; set; }
    public int? Button { get; set; }
    public int? Clicks { get; set; }
    public double? Dx { get; set; }
    public double? Dy { get; set; }
    public string? Code { get; set; }
    public bool? Down { get; set; }
    public int? Mods { get; set; }

    public static InputEvent Move(double x, double y) => new() { Kind = "move", X = x, Y = y };

    public static InputEvent Press(int button, bool down, double x, double y, int clicks) =>
        new() { Kind = down ? "down" : "up", Button = button, X = x, Y = y, Clicks = clicks };

    public static InputEvent Drag(int button, double x, double y) => new() { Kind = "drag", Button = button, X = x, Y = y };

    public static InputEvent Scroll(double dx, double dy) => new() { Kind = "scroll", Dx = dx, Dy = dy };

    public static InputEvent Key(string code, bool down, int mods) => new() { Kind = "key", Code = code, Down = down, Mods = mods };
}

sealed record StreamSettings(int Fps, int MaxWidth, double Quality, bool Live)
{
    public static readonly StreamSettings Thumbnail = new(1, 480, 0.45, false);
}

/// <summary>Every control message: one flat JSON object with a "type".</summary>
sealed class NetMessage
{
    public string Type { get; set; } = "";
    public string? Role { get; set; }
    public string? Id { get; set; }
    public string? Name { get; set; }
    public string? User { get; set; }
    public string? Computer { get; set; }
    public string? Os { get; set; }
    public string? Version { get; set; }
    public string? Text { get; set; }
    public string? Url { get; set; }
    public bool? Enabled { get; set; }
    public int? Fps { get; set; }
    public int? MaxWidth { get; set; }
    public double? Quality { get; set; }
    public bool? Live { get; set; }
    public InputEvent? Input { get; set; }
    public bool? ScreenOk { get; set; }
    public bool? ControlOk { get; set; }
    public bool? Locked { get; set; }
    public string? Platform { get; set; }
    public long? Size { get; set; }
    public string? Sha256 { get; set; }
    public string? Signature { get; set; }
    public string? Action { get; set; }
    public double? X { get; set; }
    public double? Y { get; set; }

    public static NetMessage Hello(string name) =>
        new() { Type = "hello", Role = "teacher", Name = name, Version = AppInfo.Version, Os = "windows" };

    public static NetMessage Stream(StreamSettings s) =>
        new() { Type = "stream", Fps = s.Fps, MaxWidth = s.MaxWidth, Quality = s.Quality, Live = s.Live };

    public static NetMessage Notice(string text) => new() { Type = "notice", Text = text };

    public static NetMessage UpdateBegin(PackageInfo p) => new()
    {
        Type = "updateBegin", Platform = p.Platform, Version = p.Version,
        Size = p.Size, Sha256 = p.Sha256, Signature = p.Signature,
    };

    public StreamSettings StreamSettings => new(Fps ?? 1, MaxWidth ?? 480, Quality ?? 0.5, Live ?? false);
}

/// <summary>One UDP discovery datagram.</summary>
sealed class DiscoveryPacket
{
    [JsonPropertyName("tpc")] public int Tpc { get; set; } = 1;
    [JsonPropertyName("kind")] public string Kind { get; set; } = "";
    [JsonPropertyName("class")] public string ClassTag { get; set; } = "";
    [JsonPropertyName("id")] public string? Id { get; set; }
    [JsonPropertyName("name")] public string? Name { get; set; }
    [JsonPropertyName("user")] public string? User { get; set; }
    [JsonPropertyName("os")] public string? Os { get; set; }
    [JsonPropertyName("version")] public string? Version { get; set; }
    [JsonPropertyName("port")] public int? Port { get; set; }
}

static class Versions
{
    /// <summary>True if a is newer than b ("1.0.10" &gt; "1.0.9").</summary>
    public static bool IsNewer(string? a, string? b)
    {
        var x = Parts(a);
        var y = Parts(b);
        for (int i = 0; i < Math.Max(x.Length, y.Length); i++)
        {
            int left = i < x.Length ? x[i] : 0;
            int right = i < y.Length ? y[i] : 0;
            if (left != right) return left > right;
        }
        return false;
    }

    static int[] Parts(string? v) =>
        (v ?? "0").Split('.').Select(p => int.TryParse(new string(p.TakeWhile(char.IsDigit).ToArray()), out var n) ? n : 0).ToArray();
}
