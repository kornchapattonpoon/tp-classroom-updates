using System.Security.Cryptography;
using System.Text;

namespace TPClassroom.Core;

/// <summary>Class code → shared key and discovery tag (see PROTOCOL.md).</summary>
static class ClassCrypto
{
    static readonly Dictionary<string, byte[]> Cache = new();
    static readonly object Gate = new();

    public static string Normalize(string code) => code.Trim().ToUpperInvariant();

    /// <summary>PBKDF2-HMAC-SHA256, 50 000 rounds, 32 bytes. Cached.</summary>
    public static byte[] Key(string code)
    {
        var normalized = Normalize(code);
        lock (Gate)
        {
            if (Cache.TryGetValue(normalized, out var cached)) return cached;
        }
        var key = Rfc2898DeriveBytes.Pbkdf2(Encoding.UTF8.GetBytes(normalized),
                                             Encoding.UTF8.GetBytes("TPClassroom/v1/class"),
                                             50000, HashAlgorithmName.SHA256, 32);
        lock (Gate)
        {
            Cache[normalized] = key;
        }
        return key;
    }

    /// <summary>Short public tag so classrooms on the same network ignore each other.</summary>
    public static string Tag(string code)
    {
        var mac = HMACSHA256.HashData(Key(code), Encoding.UTF8.GetBytes("TPClassroom/v1/beacon"));
        return Convert.ToHexString(mac, 0, 8).ToLowerInvariant();
    }
}
