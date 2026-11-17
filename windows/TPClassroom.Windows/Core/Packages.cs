using System.Buffers.Binary;
using System.Diagnostics;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace TPClassroom.Core;

/// <summary>Signed update package description (the .json next to each package).</summary>
sealed class PackageInfo
{
    public string Platform { get; set; } = "";
    public string Version { get; set; } = "";
    public string Sha256 { get; set; } = "";
    public string Signature { get; set; } = "";
    public long? Size { get; set; }
}

/// <summary>Checks SHA-256 + ECDSA P-256 signatures made with your private key.</summary>
static class PackageVerifier
{
    public static void Verify(byte[] data, string sha256, string signature)
    {
        if (string.IsNullOrEmpty(AppInfo.PublicKey))
            throw new InvalidOperationException("Updates aren't set up in this build (no public key).");
        var hash = Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();
        if (hash != sha256.ToLowerInvariant())
            throw new InvalidOperationException("The update was damaged on the way.");
        using var ecdsa = ECDsa.Create();
        ecdsa.ImportSubjectPublicKeyInfo(Convert.FromBase64String(AppInfo.PublicKey), out _);
        if (!ecdsa.VerifyData(data, Convert.FromBase64String(signature), HashAlgorithmName.SHA256,
                              DSASignatureFormat.IeeeP1363FixedFieldConcatenation))
            throw new InvalidOperationException("The update isn't signed with your key, so it was not installed.");
    }
}

/// <summary>
/// The Windows app carries its own signature at the end of the file:
/// [exe][signature JSON][8-byte little-endian JSON length]["TPCSIG01"].
/// Windows ignores data after the program, so the file still runs normally.
/// </summary>
static class SignedExe
{
    static readonly byte[] Magic = Encoding.ASCII.GetBytes("TPCSIG01");

    public static byte[] Append(byte[] exe, PackageInfo info)
    {
        var json = JsonSerializer.SerializeToUtf8Bytes(info, Json.Options);
        var result = new byte[exe.Length + json.Length + 16];
        exe.CopyTo(result, 0);
        json.CopyTo(result, exe.Length);
        BinaryPrimitives.WriteUInt64LittleEndian(result.AsSpan(exe.Length + json.Length, 8), (ulong)json.Length);
        Magic.CopyTo(result, exe.Length + json.Length + 8);
        return result;
    }

    public static (byte[] Exe, PackageInfo? Info) Split(byte[] file)
    {
        if (file.Length < 16 || !file.AsSpan(file.Length - 8).SequenceEqual(Magic)) return (file, null);
        ulong length = BinaryPrimitives.ReadUInt64LittleEndian(file.AsSpan(file.Length - 16, 8));
        if (length == 0 || length > (ulong)(file.Length - 16)) return (file, null);
        int jsonStart = file.Length - 16 - (int)length;
        try
        {
            var info = JsonSerializer.Deserialize<PackageInfo>(file.AsSpan(jsonStart, (int)length), Json.Options);
            return (file[..jsonStart], info);
        }
        catch (JsonException)
        {
            return (file, null);
        }
    }
}

/// <summary>Student apps this program can send to students, always the same version as itself.</summary>
static class StudentPackages
{
    public static (byte[] Data, PackageInfo Info)? For(string os)
    {
        try
        {
            if (os == "windows")
            {
                // This very program is the Windows student app; its signature is stored at the end of the file.
                using var file = new FileStream(AppInfo.ExePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                using var copy = new MemoryStream();
                file.CopyTo(copy);
                var (exe, info) = SignedExe.Split(copy.ToArray());
                if (info == null || info.Version != AppInfo.Version) return null;
                return (exe, info);
            }
            else
            {
                var assembly = Assembly.GetExecutingAssembly();
                using var zip = assembly.GetManifestResourceStream("student-mac.zip");
                using var json = assembly.GetManifestResourceStream("student-mac.zip.json");
                if (zip == null || json == null) return null;
                var info = JsonSerializer.Deserialize<PackageInfo>(json, Json.Options);
                if (info == null || info.Version != AppInfo.Version) return null;
                using var copy = new MemoryStream();
                zip.CopyTo(copy);
                return (copy.ToArray(), info);
            }
        }
        catch
        {
            return null;
        }
    }
}

/// <summary>Replaces the running TPClassroom.exe with a verified new version and restarts it.</summary>
static class WindowsInstaller
{
    public static void CleanupOld()
    {
        try { File.Delete(AppInfo.ExePath + ".old"); } catch { /* still in use or not there */ }
    }

    public static void InstallAndRelaunch(byte[] exe, PackageInfo info, string? notes, bool background)
    {
        var current = AppInfo.ExePath;
        var newPath = current + ".new";
        var oldPath = current + ".old";
        File.WriteAllBytes(newPath, SignedExe.Append(exe, info));
        try { File.Delete(oldPath); } catch { /* ignore */ }
        File.Move(current, oldPath);          // allowed while running
        try
        {
            File.Move(newPath, current);
        }
        catch
        {
            File.Move(oldPath, current);
            throw;
        }
        UpdateMarker.Set(info.Version, notes);

        var arguments = background ? "--background --updated" : "--updated";
        Process.Start(new ProcessStartInfo(current, arguments)
        {
            UseShellExecute = false,
            WorkingDirectory = Path.GetDirectoryName(current) ?? "",
        });
        Program.QuitCompletely();
    }
}

/// <summary>Remembers "you just updated" so the app can say "Update completed" with what's new.</summary>
static class UpdateMarker
{
    sealed record Marker(string Version, string? Notes);

    static string File_ => Path.Combine(AppInfo.UserDataDir, "just-updated.json");

    public static void Set(string version, string? notes)
    {
        try
        {
            Directory.CreateDirectory(AppInfo.UserDataDir);
            File.WriteAllText(File_, JsonSerializer.Serialize(new Marker(version, notes), Json.Options));
        }
        catch
        {
            // Not important.
        }
    }

    public static (string Version, string? Notes)? Take()
    {
        try
        {
            if (!File.Exists(File_)) return null;
            var marker = JsonSerializer.Deserialize<Marker>(File.ReadAllText(File_), Json.Options);
            File.Delete(File_);
            if (marker == null || marker.Version != AppInfo.Version) return null;
            return (marker.Version, string.IsNullOrWhiteSpace(marker.Notes) ? null : marker.Notes);
        }
        catch
        {
            return null;
        }
    }
}
