using System.Text.Json;
using TPClassroom.Core;

namespace TPClassroom.Teacher;

/// <summary>
/// The teacher app on Windows. Lives in the notification area, so closing or "quitting" the window keeps
/// it running and students stay connected. Remembers every student computer it has seen.
/// </summary>
sealed class TeacherContext : ApplicationContext
{
    readonly NotifyIcon tray;
    readonly System.Windows.Forms.Timer probeTimer = new() { Interval = 10000 };
    readonly System.Windows.Forms.Timer reconnectTimer = new() { Interval = 5000 };
    Discovery? discovery;
    MainForm? mainForm;
    AiForm? aiForm;
    string classTag = "";

    public AppConfig Config { get; }
    public byte[]? ClassKey { get; private set; }
    public List<TeacherSession> Sessions { get; } = new();
    public Updater Updater { get; } = new();
    /// <summary>TP AI, the assistant that can run the class for the teacher.</summary>
    public AiAssistant Ai { get; }
    public string DiscoveryStatus { get; private set; } = "";
    public HashSet<TeacherSession> LiveSessions { get; } = new();

    /// <summary>Students were added, removed or re-ordered.</summary>
    public event Action? SessionsChanged;
    /// <summary>Counts or status text changed.</summary>
    public event Action? StatusChanged;

    static string RosterFile => Path.Combine(AppInfo.UserDataDir, "roster.json");

    public TeacherContext(AppConfig config, bool startHidden)
    {
        Config = config;
        Ai = new AiAssistant(this);
        tray = new NotifyIcon
        {
            Icon = Program.LoadIcon("teacher.ico"),
            Text = "TP Classroom",
            Visible = true,
            ContextMenuStrip = new ContextMenuStrip(),
        };
        tray.ContextMenuStrip.Opening += (_, _) => BuildTrayMenu();
        tray.DoubleClick += (_, _) => ShowMainWindow();

        LoadRoster();
        Updater.ShouldDefer = () => LiveSessions.Count > 0;
        Updater.RelaunchInBackground = () => mainForm == null || !mainForm.Visible;
        Updater.Changed += () => StatusChanged?.Invoke();
        Program.ShowRequested += ShowMainWindow;

        Start();
        Updater.Start();

        var done = UpdateMarker.Take();
        if (!startHidden) ShowMainWindow();
        if (done != null)
        {
            var text = $"TP Classroom is now version {done.Value.Version}.";
            if (done.Value.Notes != null) text += "\n\nWhat's new:\n" + done.Value.Notes;
            if (startHidden) tray.ShowBalloonTip(8000, "Update completed", text, ToolTipIcon.Info);
            else MessageBox.Show(text, "Update completed", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
    }

    public StreamSettings LiveSettings => Config.LiveQuality switch
    {
        "smooth" => new StreamSettings(15, 1280, 0.5, true),
        "balanced" => new StreamSettings(12, 1680, 0.6, true),
        _ => new StreamSettings(15, 2880, 0.85, true),   // Best (the default)
    };

    public int OnlineCount => Sessions.Count(s => s.IsOnline);

    // MARK: Starting

    void Start()
    {
        if (string.IsNullOrEmpty(Config.NormalizedClassCode)) return;
        ClassKey = ClassCrypto.Key(Config.NormalizedClassCode);
        classTag = ClassCrypto.Tag(Config.NormalizedClassCode);

        if (discovery == null)
        {
            try
            {
                discovery = new Discovery();
                discovery.PacketReceived += HandleBeacon;
                discovery.Start();
                DiscoveryStatus = "Looking for student computers on this network…";
            }
            catch (Exception ex)
            {
                DiscoveryStatus = "Can't listen for students (port 52801 busy): " + ex.Message;
            }
        }

        foreach (var session in Sessions) session.ConnectIfIdle();
        probeTimer.Tick += (_, _) => SendProbe();
        reconnectTimer.Tick += (_, _) => { foreach (var s in Sessions.ToList()) s.ConnectIfIdle(); };
        probeTimer.Start();
        reconnectTimer.Start();
        SendProbe();
    }

    public void SetClassCode(string code)
    {
        var normalized = ClassCrypto.Normalize(code);
        if (normalized.Length == 0 || normalized == Config.NormalizedClassCode) return;
        Config.ClassCode = normalized;
        Config.Save();
        ClassKey = ClassCrypto.Key(normalized);
        classTag = ClassCrypto.Tag(normalized);
        foreach (var session in Sessions) session.Disconnect();
        foreach (var session in Sessions) session.Connect();
        SendProbe();
        StatusChanged?.Invoke();
    }

    public void ReconnectAll()
    {
        foreach (var session in Sessions) session.Connect();
        SendProbe();
    }

    void SendProbe()
    {
        if (discovery == null || classTag.Length == 0) return;
        var probe = new DiscoveryPacket { Kind = "probe", ClassTag = classTag };
        discovery.Broadcast(probe);
        foreach (var session in Sessions.Where(s => !s.IsOnline && !string.IsNullOrEmpty(s.Host)))
            discovery.SendTo(probe, session.Host);
    }

    void HandleBeacon(DiscoveryPacket packet, string ip)
    {
        if (packet.Kind != "student" || packet.ClassTag != classTag || string.IsNullOrEmpty(packet.Id)) return;
        var existing = Sessions.FirstOrDefault(s => s.Id == packet.Id);
        if (existing != null)
        {
            existing.UpdateFromBeacon(packet, ip);
            existing.ConnectIfIdle();
            return;
        }
        var session = AddSession(new KnownStudent
        {
            Id = packet.Id, Name = packet.Name ?? ip, User = packet.User ?? "", Os = packet.Os ?? "mac",
            Version = packet.Version ?? "", Host = ip, Port = packet.Port ?? Ports.Tcp, LastSeen = DateTime.Now,
        });
        SaveRoster();
        session.Connect();
    }

    /// <summary>Fallback when broadcasts are blocked: connect to an address once; after that it's remembered.</summary>
    public void AddByAddress(string text)
    {
        text = text.Trim();
        if (text.Length == 0) return;
        var host = text;
        int port = Ports.Tcp;
        var parts = text.Split(':');
        if (parts.Length == 2 && int.TryParse(parts[1], out var customPort))
        {
            host = parts[0];
            port = customPort;
        }
        var existing = Sessions.FirstOrDefault(s => s.Host == host);
        if (existing != null)
        {
            existing.Connect();
            return;
        }
        var session = AddSession(new KnownStudent { Id = "address:" + host, Name = host, Host = host, Port = port, LastSeen = DateTime.Now });
        session.Connect();
    }

    TeacherSession AddSession(KnownStudent known)
    {
        var session = new TeacherSession(known, this);
        Sessions.Add(session);
        Sort();
        SessionsChanged?.Invoke();
        return session;
    }

    public void Forget(TeacherSession session)
    {
        session.Disconnect();
        Sessions.Remove(session);
        SaveRoster();
        SessionsChanged?.Invoke();
    }

    public void SessionStatusChanged() => StatusChanged?.Invoke();

    public void StudentChangedId(TeacherSession session, string newId)
    {
        var duplicate = Sessions.FirstOrDefault(s => s.Id == newId && s != session);
        if (duplicate != null)
        {
            duplicate.Disconnect();
            Sessions.Remove(duplicate);
            SessionsChanged?.Invoke();
        }
    }

    public void StudentInfoChanged(TeacherSession session, bool justConnected)
    {
        SaveRoster();
        if (justConnected) Sort();
        StatusChanged?.Invoke();
        KeepVersionsTheSame(session);
    }

    void Sort()
    {
        Sessions.Sort((a, b) => string.Compare(a.Name, b.Name, StringComparison.CurrentCultureIgnoreCase));
    }

    void LoadRoster()
    {
        try
        {
            if (!File.Exists(RosterFile)) return;
            var roster = JsonSerializer.Deserialize<List<KnownStudent>>(File.ReadAllText(RosterFile), Json.Options);
            if (roster == null) return;
            foreach (var known in roster) Sessions.Add(new TeacherSession(known, this));
            Sort();
        }
        catch
        {
            // Start with an empty list.
        }
    }

    public void SaveRoster()
    {
        try
        {
            Directory.CreateDirectory(AppInfo.UserDataDir);
            var roster = Sessions.Where(s => !s.Id.StartsWith("address:")).Select(s => s.Known).ToList();
            File.WriteAllText(RosterFile, JsonSerializer.Serialize(roster, Json.Options));
        }
        catch
        {
            // Not fatal.
        }
    }

    // MARK: Same version everywhere

    /// <summary>Older students get the teacher's version over the local network; if a student is newer, update the teacher.</summary>
    void KeepVersionsTheSame(TeacherSession session)
    {
        if (!session.IsOnline || string.IsNullOrEmpty(session.Version)) return;
        if (Versions.IsNewer(AppInfo.Version, session.Version))
        {
            var package = StudentPackages.For(session.Os);
            if (package != null)
            {
                session.Notice = null;
                session.SendUpdate(package.Value.Data, package.Value.Info);
            }
            else
            {
                var platform = session.IsWindows ? "Windows" : "Mac";
                session.Notice = $"This computer has an older version, but this build doesn't include the {platform} student app.";
            }
        }
        else if (Versions.IsNewer(session.Version, AppInfo.Version))
        {
            session.Notice = $"This computer has a newer version ({session.Version}). The teacher app will update itself when it's online.";
            _ = Updater.CheckAsync(false);
        }
    }

    // MARK: Class-wide actions

    public void LockAll(string message)
    {
        foreach (var session in Sessions) session.Lock(message);
    }

    public void UnlockAll()
    {
        foreach (var session in Sessions) session.Unlock();
    }

    public void MessageAll(string text)
    {
        foreach (var session in Sessions) session.Send(new NetMessage { Type = "message", Text = text });
    }

    public void OpenWebsiteAll(string text)
    {
        var url = NormalizeUrl(text);
        if (url == null) return;
        foreach (var session in Sessions) session.Send(new NetMessage { Type = "openUrl", Url = url });
    }

    /// <summary>"google.com" → "https://google.com". Only web links are allowed.</summary>
    public static string? NormalizeUrl(string text)
    {
        text = text.Trim();
        if (text.Length == 0) return null;
        if (!text.Contains("://")) text = "https://" + text;
        return Uri.TryCreate(text, UriKind.Absolute, out var uri) &&
               (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps) ? uri.AbsoluteUri : null;
    }

    // MARK: Windows and tray

    public void ShowMainWindow()
    {
        if (mainForm == null || mainForm.IsDisposed) mainForm = new MainForm(this);
        mainForm.Show();
        if (mainForm.WindowState == FormWindowState.Minimized) mainForm.WindowState = FormWindowState.Normal;
        mainForm.Activate();
    }

    /// <summary>TP AI is about to click or type on a student: show that screen next to the TP AI chat.</summary>
    public void WatchLive(TeacherSession session)
    {
        if (mainForm == null || mainForm.IsDisposed) mainForm = new MainForm(this);
        var (live, isNew) = mainForm.OpenLive(session, activate: false);
        if (aiForm == null || aiForm.IsDisposed || !aiForm.Visible) return;
        if (isNew)
        {
            var area = Screen.FromControl(aiForm).WorkingArea;
            int aiWidth = Math.Min(Math.Max(aiForm.Width, 420), area.Width * 2 / 5);
            aiForm.WindowState = FormWindowState.Normal;
            live.WindowState = FormWindowState.Normal;
            aiForm.Bounds = new Rectangle(area.Right - aiWidth, area.Top, aiWidth, area.Height);
            live.Bounds = new Rectangle(area.Left, area.Top, area.Width - aiWidth, area.Height);
        }
        aiForm.Activate();   // keep typing in the TP AI chat
    }

    public void ShowAi()
    {
        if (aiForm == null || aiForm.IsDisposed) aiForm = new AiForm(Ai);
        aiForm.Show();
        if (aiForm.WindowState == FormWindowState.Minimized) aiForm.WindowState = FormWindowState.Normal;
        aiForm.Activate();
    }

    void BuildTrayMenu()
    {
        var menu = tray.ContextMenuStrip!;
        menu.Items.Clear();
        menu.Items.Add(new ToolStripMenuItem($"TP Classroom {AppInfo.Version} — {OnlineCount} of {Sessions.Count} online") { Enabled = false });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Open TP Classroom", null, (_, _) => ShowMainWindow()));
        menu.Items.Add(new ToolStripMenuItem("Ask TP AI…", null, (_, _) => ShowAi()));
        menu.Items.Add(new ToolStripMenuItem("Lock All Screens", null, (_, _) => LockAll("Eyes on the teacher, please")));
        menu.Items.Add(new ToolStripMenuItem("Unlock All Screens", null, (_, _) => UnlockAll()));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Start with Windows", null, (_, _) => AutoStart.Set(!AutoStart.IsEnabled))
        {
            Checked = AutoStart.IsEnabled,
        });
        menu.Items.Add(new ToolStripMenuItem("Check for Updates", null, async (_, _) => await Updater.CheckAsync(true)));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Quit TP Classroom Completely", null, (_, _) => Program.QuitCompletely()));
    }

    /// <summary>First time the window is closed, explain that the app keeps running.</summary>
    public void ShowBackgroundTipOnce()
    {
        var flag = Path.Combine(AppInfo.UserDataDir, "background-tip-shown");
        if (File.Exists(flag)) return;
        try
        {
            Directory.CreateDirectory(AppInfo.UserDataDir);
            File.WriteAllText(flag, "yes");
        }
        catch
        {
            // ignore
        }
        tray.ShowBalloonTip(8000, "TP Classroom keeps running",
            "It stays in the notification area so your students stay connected. To quit completely, right-click the icon → Quit TP Classroom Completely.",
            ToolTipIcon.Info);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            tray.Visible = false;
            tray.Dispose();
            discovery?.Dispose();
            foreach (var session in Sessions) session.Disconnect();
        }
        base.Dispose(disposing);
    }
}
