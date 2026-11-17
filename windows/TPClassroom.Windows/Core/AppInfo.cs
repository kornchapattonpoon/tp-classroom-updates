using System.Reflection;
using Microsoft.Win32;

namespace TPClassroom.Core;

static class AppInfo
{
    public static string Version { get; } = ReadVersion();
    public static string DeviceId { get; } = ReadDeviceId();

    public static string FeedUrl => Metadata("UpdateFeedUrl");
    public static string PublicKey => Metadata("UpdatePublicKey");
    public static string ComputerName => Environment.MachineName;
    public static string UserName => Environment.UserName;
    public static string ExePath => Environment.ProcessPath ?? Application.ExecutablePath;

    /// <summary>C:\ProgramData\TPClassroom — written by the installer, readable by everyone.</summary>
    public static string MachineDataDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "TPClassroom");

    /// <summary>%APPDATA%\TPClassroom — this user's settings and remembered students.</summary>
    public static string UserDataDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "TPClassroom");

    static string ReadVersion()
    {
        var text = Assembly.GetExecutingAssembly()
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "0.0.0";
        var plus = text.IndexOf('+');
        return plus >= 0 ? text[..plus] : text;
    }

    public static string Metadata(string key) =>
        Assembly.GetExecutingAssembly().GetCustomAttributes<AssemblyMetadataAttribute>()
            .FirstOrDefault(a => a.Key == key)?.Value ?? "";

    /// <summary>Stable ID of this PC (same for every user).</summary>
    static string ReadDeviceId()
    {
        try
        {
            using var key = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64)
                .OpenSubKey(@"SOFTWARE\Microsoft\Cryptography");
            if (key?.GetValue("MachineGuid") is string guid && guid.Length > 0)
                return "win-" + guid.ToLowerInvariant();
        }
        catch
        {
            // Fall back to a saved random ID below.
        }
        var file = Path.Combine(UserDataDir, "device-id.txt");
        try
        {
            if (File.Exists(file)) return File.ReadAllText(file).Trim();
            Directory.CreateDirectory(UserDataDir);
            var made = "win-" + Guid.NewGuid().ToString().ToLowerInvariant();
            File.WriteAllText(file, made);
            return made;
        }
        catch
        {
            return "win-" + Environment.MachineName.ToLowerInvariant();
        }
    }
}
