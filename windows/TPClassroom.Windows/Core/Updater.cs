using System.Text.Json;

namespace TPClassroom.Core;

sealed class UpdateFeed
{
    public string Version { get; set; } = "";
    public string? Notes { get; set; }
    public Dictionary<string, FeedAsset> Assets { get; set; } = new();
}

sealed class FeedAsset
{
    public string Url { get; set; } = "";
    public string Sha256 { get; set; } = "";
    public string Signature { get; set; } = "";
    public long? Size { get; set; }
}

/// <summary>
/// Keeps the Windows teacher app up to date from the internet.
/// Students get the same version from the teacher over the local network.
/// </summary>
sealed class Updater
{
    readonly System.Windows.Forms.Timer checkTimer = new() { Interval = 2 * 60 * 60 * 1000 };
    readonly System.Windows.Forms.Timer retryTimer = new() { Interval = 10 * 60 * 1000 };
    UpdateFeed? pending;
    bool busy;

    public string Status { get; private set; } = "Automatic updates on";
    public bool HasPendingUpdate => pending != null;
    public event Action? Changed;

    /// <summary>Return true to wait (e.g. while a live window is open).</summary>
    public Func<bool>? ShouldDefer { get; set; }
    /// <summary>Should the app come back hidden after the update?</summary>
    public Func<bool>? RelaunchInBackground { get; set; }

    static bool Configured =>
        !string.IsNullOrEmpty(AppInfo.FeedUrl) && !AppInfo.FeedUrl.Contains("YOUR_") && !string.IsNullOrEmpty(AppInfo.PublicKey);

    public void Start()
    {
        checkTimer.Tick += async (_, _) => await CheckAsync(false);
        retryTimer.Tick += async (_, _) => { if (pending != null) await InstallIfAllowedAsync(); };
        checkTimer.Start();
        retryTimer.Start();
        _ = CheckAsync(false);
    }

    void SetStatus(string text)
    {
        Status = text;
        Changed?.Invoke();
    }

    public async Task CheckAsync(bool userInitiated)
    {
        if (busy) return;
        if (!Configured)
        {
            if (userInitiated) SetStatus("Updates aren't set up in this build");
            return;
        }
        busy = true;
        SetStatus("Checking for updates…");
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
            var text = await http.GetStringAsync(AppInfo.FeedUrl);
            var feed = JsonSerializer.Deserialize<UpdateFeed>(text, Json.Options);
            if (feed == null || !Versions.IsNewer(feed.Version, AppInfo.Version) || !feed.Assets.ContainsKey("windows"))
            {
                pending = null;
                SetStatus("Up to date");
                return;
            }
            pending = feed;
            SetStatus($"Version {feed.Version} will install soon");
        }
        catch
        {
            SetStatus(userInitiated ? "Couldn't reach the update server (no internet?)" : "Automatic updates on");
            return;
        }
        finally
        {
            busy = false;
        }
        await InstallIfAllowedAsync();
    }

    public async Task InstallIfAllowedAsync()
    {
        if (ShouldDefer?.Invoke() == true) return;
        await InstallNowAsync();
    }

    public async Task InstallNowAsync()
    {
        if (pending == null || busy) return;
        var feed = pending;
        var asset = feed.Assets["windows"];
        busy = true;
        SetStatus("Downloading update…");
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
            var file = await http.GetByteArrayAsync(asset.Url);
            PackageVerifier.Verify(file, asset.Sha256, asset.Signature);

            // The download is the setup exe; its own signature is stored at its end.
            var (exe, info) = SignedExe.Split(file);
            if (info == null) throw new InvalidOperationException("The update is missing its signature.");
            PackageVerifier.Verify(exe, info.Sha256, info.Signature);

            SetStatus("Installing update…");
            WindowsInstaller.InstallAndRelaunch(exe, info, feed.Notes, RelaunchInBackground?.Invoke() ?? false);
        }
        catch (Exception ex)
        {
            SetStatus("Update problem: " + ex.Message);
        }
        finally
        {
            busy = false;
        }
    }
}
