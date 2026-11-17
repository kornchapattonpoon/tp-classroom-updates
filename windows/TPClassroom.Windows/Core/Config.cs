using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32;

namespace TPClassroom.Core;

/// <summary>
/// Settings. The installer writes C:\ProgramData\TPClassroom\config.json (role, class code, admin PIN)
/// for every user on the PC; anything else is saved per user in %APPDATA%\TPClassroom\config.json.
/// </summary>
sealed class AppConfig
{
    public string? Role { get; set; }            // "teacher" or "student"
    public string? ClassCode { get; set; }
    public string? AdminPinHash { get; set; }
    public string? DisplayName { get; set; }
    public string? TeacherName { get; set; }
    public string? LiveQuality { get; set; }
    /// <summary>TP AI key, saved only for this teacher (the same .exe also goes to students, so no key is built in).</summary>
    public string? AiApiKey { get; set; }

    [JsonIgnore] public bool Managed { get; private set; }

    static string MachineFile => Path.Combine(AppInfo.MachineDataDir, "config.json");
    static string UserFile => Path.Combine(AppInfo.UserDataDir, "config.json");

    [JsonIgnore] public bool IsTeacher => Role == "teacher";
    [JsonIgnore] public string NormalizedClassCode => ClassCrypto.Normalize(ClassCode ?? "");
    [JsonIgnore] public bool HasPin => !string.IsNullOrEmpty(AdminPinHash);
    [JsonIgnore] public string StudentName => string.IsNullOrWhiteSpace(DisplayName) ? AppInfo.ComputerName : DisplayName.Trim();
    [JsonIgnore] public string TeacherDisplayName => string.IsNullOrWhiteSpace(TeacherName) ? AppInfo.UserName : TeacherName.Trim();

    public static AppConfig Load()
    {
        var config = Read(UserFile) ?? new AppConfig();
        var machine = Read(MachineFile);
        if (machine != null && !string.IsNullOrEmpty(machine.ClassCode))
        {
            config.Role = machine.Role ?? config.Role ?? "student";
            config.ClassCode = machine.ClassCode;
            config.AdminPinHash = machine.AdminPinHash;
            if (string.IsNullOrWhiteSpace(config.TeacherName)) config.TeacherName = machine.TeacherName;
            if (string.IsNullOrWhiteSpace(config.DisplayName)) config.DisplayName = machine.DisplayName;
            config.Managed = true;
        }
        return config;
    }

    public void Save()
    {
        Directory.CreateDirectory(AppInfo.UserDataDir);
        File.WriteAllText(UserFile, JsonSerializer.Serialize(this, Json.Options));
    }

    public bool VerifyPin(string pin) => !HasPin || HashPin(pin) == AdminPinHash!.ToLowerInvariant();

    public static string HashPin(string pin) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(pin))).ToLowerInvariant();

    static AppConfig? Read(string file)
    {
        try
        {
            return File.Exists(file) ? JsonSerializer.Deserialize<AppConfig>(File.ReadAllText(file), Json.Options) : null;
        }
        catch
        {
            return null;
        }
    }
}

/// <summary>Start with Windows (this user only; the installer sets it for everyone).</summary>
static class AutoStart
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string ValueName = "TP Classroom";

    public static bool IsEnabled
    {
        get
        {
            using var user = Registry.CurrentUser.OpenSubKey(RunKey);
            using var machine = Registry.LocalMachine.OpenSubKey(RunKey);
            return user?.GetValue(ValueName) != null || machine?.GetValue(ValueName) != null;
        }
    }

    public static void Set(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (enabled) key.SetValue(ValueName, $"\"{AppInfo.ExePath}\" --background");
            else key.DeleteValue(ValueName, false);
        }
        catch
        {
            // Not fatal.
        }
    }
}
