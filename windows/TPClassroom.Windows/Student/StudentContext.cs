using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using TPClassroom.Core;

namespace TPClassroom.Student;

/// <summary>One connected teacher.</summary>
sealed class TeacherClient
{
    public TeacherClient(SecureConnection connection) => Connection = connection;

    public SecureConnection Connection { get; }
    public string Name { get; set; } = "Teacher";
    public string Os { get; set; } = "windows";
    public bool Greeted { get; set; }
    public volatile StreamSettings? Stream;
    public bool ControlEnabled { get; set; }
    public bool LockedScreen { get; set; }

    // Used by the capture thread.
    public volatile bool Sending;
    public int SentHash;
    public long LastSentTicks;

    // An update arriving from this teacher.
    public PackageInfo? IncomingInfo { get; set; }
    public MemoryStream? IncomingData { get; set; }
}

/// <summary>
/// The student app on Windows: tray icon, announces itself on the network, accepts teachers,
/// streams the screen, performs remote input and installs updates from the teacher.
/// </summary>
sealed class StudentContext : ApplicationContext
{
    readonly AppConfig config;
    readonly byte[] classKey;
    readonly string classTag;
    readonly object gate = new();
    readonly List<TeacherClient> clients = new();
    readonly NotifyIcon tray;
    readonly Icon normalIcon;
    readonly Icon viewedIcon;
    readonly LockScreen lockScreen = new();
    readonly BannerForm banner = new();
    readonly ScreenCapture capture = new();
    readonly CancellationTokenSource stopping = new();
    readonly System.Windows.Forms.Timer beaconTimer = new() { Interval = 3000 };
    Discovery? discovery;
    TcpListener? listener;
    int listenPort = Ports.Tcp;
    string networkStatus = "Starting…";
    bool updating;
    (byte[] Data, PackageInfo Info)? verifiedUpdate;

    public StudentContext(AppConfig config)
    {
        this.config = config;
        classKey = ClassCrypto.Key(config.NormalizedClassCode);
        classTag = ClassCrypto.Tag(config.NormalizedClassCode);
        normalIcon = Program.LoadIcon("student.ico");
        viewedIcon = Program.LoadIcon("student-viewed.ico");

        tray = new NotifyIcon { Icon = normalIcon, Text = "TP Classroom Student", Visible = true, ContextMenuStrip = new ContextMenuStrip() };
        tray.ContextMenuStrip.Opening += (_, _) => BuildMenu(tray.ContextMenuStrip);

        lockScreen.VerifyPin = AdminUnlock;

        StartListening();
        StartDiscovery();
        beaconTimer.Tick += (_, _) => SendBeacon();
        beaconTimer.Start();
        _ = Task.Run(() => CaptureLoopAsync(stopping.Token));

        var done = UpdateMarker.Take();
        if (done != null) banner.Flash($"Update completed: TP Classroom {done.Value.Version}");
    }

    // MARK: Tray menu

    void BuildMenu(ContextMenuStrip menu)
    {
        menu.Items.Clear();
        menu.Items.Add(new ToolStripMenuItem($"TP Classroom Student {AppInfo.Version}") { Enabled = false });
        menu.Items.Add(new ToolStripMenuItem(StatusLine) { Enabled = false });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Settings…", null, (_, _) => OpenSettings()));
        menu.Items.Add(new ToolStripMenuItem("Stop Until Next Sign-in…", null, (_, _) => StopAskingPin()));
    }

    string StatusLine
    {
        get
        {
            var names = ReadyClients().Select(c => c.Name).Distinct().ToList();
            return names.Count == 0 ? networkStatus : "Connected to " + string.Join(", ", names);
        }
    }

    void OpenSettings()
    {
        if (!PinPrompt.Ask("Enter the admin PIN to change TP Classroom settings.", config.VerifyPin)) return;
        using var form = new SetupForm(config, studentOnly: true);
        if (form.ShowDialog() == DialogResult.OK) Program.Restart();
    }

    void StopAskingPin()
    {
        if (!PinPrompt.Ask("Enter the admin PIN to stop TP Classroom until the next sign-in.", config.VerifyPin)) return;
        Program.QuitCompletely();
    }

    bool AdminUnlock(string pin)
    {
        if (!config.HasPin || !config.VerifyPin(pin)) return false;
        foreach (var client in ReadyClients()) client.LockedScreen = false;
        lockScreen.Unlock();
        SendInfoToAll();
        InstallVerifiedUpdateIfPossible();
        return true;
    }

    // MARK: Discovery

    void StartDiscovery()
    {
        try
        {
            discovery = new Discovery();
            discovery.PacketReceived += (packet, ip) =>
            {
                if (packet.Kind != "probe" || packet.ClassTag != classTag) return;
                SendBeacon();
                discovery?.SendTo(MakeBeacon(), ip);
            };
            discovery.Start();
        }
        catch (Exception ex)
        {
            networkStatus = "Discovery port 52801 is busy: " + ex.Message;
        }
    }

    DiscoveryPacket MakeBeacon() => new()
    {
        Kind = "student", ClassTag = classTag, Id = AppInfo.DeviceId, Name = config.StudentName,
        User = AppInfo.UserName, Os = "windows", Version = AppInfo.Version, Port = listenPort,
    };

    void SendBeacon()
    {
        if (listener != null) discovery?.Broadcast(MakeBeacon());
    }

    // MARK: Listening for teachers

    void StartListening()
    {
        foreach (var port in new[] { Ports.Tcp, 0 })
        {
            try
            {
                var candidate = new TcpListener(IPAddress.Any, port);
                candidate.Start();
                listener = candidate;
                listenPort = ((IPEndPoint)candidate.LocalEndpoint).Port;
                networkStatus = "Waiting for the teacher…";
                _ = AcceptLoopAsync(candidate);
                SendBeacon();
                return;
            }
            catch (SocketException)
            {
                // Port busy: try any free port; discovery tells the teacher which one.
            }
        }
        networkStatus = "Network problem: can't listen for the teacher.";
    }

    async Task AcceptLoopAsync(TcpListener server)
    {
        while (!stopping.IsCancellationRequested)
        {
            TcpClient tcp;
            try
            {
                tcp = await server.AcceptTcpClientAsync();
            }
            catch
            {
                return;
            }
            _ = HandleNewTeacherAsync(tcp);
        }
    }

    async Task HandleNewTeacherAsync(TcpClient tcp)
    {
        SecureConnection connection;
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            connection = await SecureConnection.AcceptAsync(tcp, classKey, timeout.Token);
        }
        catch
        {
            tcp.Dispose();
            return;
        }
        var client = new TeacherClient(connection);
        lock (gate) clients.Add(client);
        connection.MessageReceived += message => Handle(client, message);
        connection.ChunkReceived += bytes => ReceiveChunk(client, bytes);
        connection.Closed += _ => Drop(client);
        connection.Start();
    }

    void Drop(TeacherClient client)
    {
        lock (gate) clients.Remove(client);
        client.Connection.Cancel();
        if (client.IncomingInfo != null)
        {
            client.IncomingData?.Dispose();
            client.IncomingInfo = null;
            updating = false;
        }
        if (client.LockedScreen && lockScreen.IsLocked) ScheduleAutoUnlock();
        RefreshState();
    }

    List<TeacherClient> ReadyClients()
    {
        lock (gate) return clients.Where(c => c.Greeted).ToList();
    }

    // MARK: Commands from the teacher

    void Handle(TeacherClient client, NetMessage message)
    {
        if (message.Type == "hello")
        {
            client.Name = string.IsNullOrWhiteSpace(message.Name) ? "Teacher" : message.Name!;
            client.Os = message.Os ?? "mac";
            client.Greeted = true;
            _ = client.Connection.SendAsync(MakeInfo());
            banner.Flash($"{client.Name} connected. Your teacher can see this screen during class.");
            tray.ShowBalloonTip(5000, "TP Classroom", $"{client.Name} connected and can see this screen.", ToolTipIcon.Info);
            RefreshState();
            return;
        }
        if (!client.Greeted) return;

        switch (message.Type)
        {
            case "stream":
                client.SentHash = 0;
                client.LastSentTicks = 0;
                client.Stream = message.StreamSettings;
                RefreshState();
                break;
            case "stopStream":
                client.Stream = null;
                RefreshState();
                break;
            case "control":
                client.ControlEnabled = message.Enabled ?? false;
                RefreshState();
                InstallVerifiedUpdateIfPossible();
                break;
            case "input":
                if (!client.ControlEnabled || message.Input == null) return;
                var input = message.Input;
                if (client.Os != "windows")
                {
                    if (input.Code != null) input.Code = KeyMap.SwapMetaAndControl(input.Code);
                    if (input.Mods != null) input.Mods = KeyMap.SwapMetaAndControl(input.Mods.Value);
                }
                InputInjector.Post(input);
                break;
            case "typeText":
                if (client.ControlEnabled && message.Text != null) InputInjector.TypeText(message.Text);
                break;
            case "power":
                PowerOff(message.Action == "restart", client.Name);
                break;
            case "lock":
                client.LockedScreen = true;
                autoUnlock?.Stop();
                lockScreen.Lock(message.Text ?? "", client.Name, config.HasPin);
                SendInfoToAll();
                break;
            case "unlock":
                foreach (var other in ReadyClients()) other.LockedScreen = false;
                autoUnlock?.Stop();
                lockScreen.Unlock();
                SendInfoToAll();
                InstallVerifiedUpdateIfPossible();
                break;
            case "message":
                var form = new MessageForm(message.Text ?? "", client.Name);
                form.Show();
                form.Activate();
                break;
            case "openUrl":
                if (Uri.TryCreate(message.Url, UriKind.Absolute, out var uri) &&
                    (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps))
                {
                    try { Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true }); }
                    catch { /* no browser */ }
                }
                break;
            case "updateBegin":
                BeginUpdate(client, message);
                break;
            case "updateEnd":
                FinishUpdate(client);
                break;
        }
    }

    bool poweringOff;

    /// <summary>Shut down or restart after a 15-second warning (Windows also shows its own notice).</summary>
    void PowerOff(bool restart, string teacher)
    {
        if (poweringOff) return;
        poweringOff = true;
        var verb = restart ? "restarting" : "shutting down";
        banner.Flash($"{teacher} is {verb} this PC in 15 seconds. Save your work!", 15);
        try
        {
            Process.Start(new ProcessStartInfo("shutdown.exe", $"{(restart ? "/r" : "/s")} /t 15 /c \"{teacher} is {verb} this PC. Save your work!\"")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
            });
        }
        catch (Exception ex)
        {
            poweringOff = false;
            NotifyAll("This PC couldn't " + (restart ? "restart" : "shut down") + ": " + ex.Message);
        }
    }

    System.Windows.Forms.Timer? autoUnlock;

    /// <summary>If the teacher app disappears while locked, unlock after 45 seconds so nobody is stuck.</summary>
    void ScheduleAutoUnlock()
    {
        autoUnlock?.Stop();
        autoUnlock = new System.Windows.Forms.Timer { Interval = 45000 };
        autoUnlock.Tick += (_, _) =>
        {
            autoUnlock?.Stop();
            if (!ReadyClients().Any(c => c.LockedScreen))
            {
                lockScreen.Unlock();
                SendInfoToAll();
                InstallVerifiedUpdateIfPossible();
            }
        };
        autoUnlock.Start();
    }

    // MARK: Updates from the teacher (same version, works offline)

    void BeginUpdate(TeacherClient client, NetMessage message)
    {
        if (message.Platform != "windows" || message.Version == null || message.Sha256 == null ||
            message.Signature == null || message.Size is not > 0 || message.Size > 500_000_000 ||
            !Versions.IsNewer(message.Version, AppInfo.Version) || updating || verifiedUpdate != null) return;
        updating = true;
        client.IncomingInfo = new PackageInfo
        {
            Platform = "windows", Version = message.Version, Sha256 = message.Sha256,
            Signature = message.Signature, Size = message.Size,
        };
        client.IncomingData = new MemoryStream((int)message.Size.Value);
    }

    void ReceiveChunk(TeacherClient client, byte[] bytes)
    {
        if (client.IncomingInfo == null || client.IncomingData == null) return;
        client.IncomingData.Write(bytes);
        if (client.IncomingData.Length > client.IncomingInfo.Size)
        {
            client.IncomingData.Dispose();
            client.IncomingData = null;
            client.IncomingInfo = null;
            updating = false;
        }
    }

    void FinishUpdate(TeacherClient client)
    {
        var info = client.IncomingInfo;
        var data = client.IncomingData;
        client.IncomingInfo = null;
        client.IncomingData = null;
        if (info == null || data == null) return;
        var bytes = data.ToArray();
        data.Dispose();
        try
        {
            if (bytes.Length != info.Size) throw new InvalidOperationException("The update was damaged on the way.");
            PackageVerifier.Verify(bytes, info.Sha256, info.Signature);
        }
        catch (Exception ex)
        {
            updating = false;
            _ = client.Connection.SendAsync(NetMessage.Notice("Update failed on this PC: " + ex.Message));
            return;
        }
        verifiedUpdate = (bytes, info);
        InstallVerifiedUpdateIfPossible();
    }

    /// <summary>Installs right away, unless the screen is locked or being controlled.</summary>
    void InstallVerifiedUpdateIfPossible()
    {
        if (verifiedUpdate == null || lockScreen.IsLocked || ReadyClients().Any(c => c.ControlEnabled)) return;
        var update = verifiedUpdate.Value;
        verifiedUpdate = null;
        try
        {
            WindowsInstaller.InstallAndRelaunch(update.Data, update.Info, null, background: true);
        }
        catch (Exception ex)
        {
            updating = false;
            NotifyAll("Update failed on this PC: " + ex.Message +
                      " (Run the TP Classroom Setup file again so updates can replace the app.)");
        }
    }

    // MARK: Screen streaming (background thread)

    async Task CaptureLoopAsync(CancellationToken token)
    {
        int lastHash = 0;
        byte[]? lastJpeg = null;
        while (!token.IsCancellationRequested)
        {
            List<(TeacherClient Client, StreamSettings Settings)> targets;
            lock (gate)
            {
                targets = clients.Where(c => c.Greeted && c.Stream != null).Select(c => (c, c.Stream!)).ToList();
            }
            if (targets.Count == 0)
            {
                await Task.Delay(300, token).ContinueWith(_ => { });
                continue;
            }

            int fps = targets.Max(t => t.Settings.Fps);
            int maxWidth = targets.Max(t => t.Settings.MaxWidth);
            double quality = targets.Max(t => t.Settings.Quality);
            var started = Stopwatch.GetTimestamp();

            var (jpeg, hash) = capture.Capture(maxWidth, quality, lastHash);
            if (jpeg != null)
            {
                lastJpeg = jpeg;
                lastHash = hash;
            }

            if (lastJpeg != null)
            {
                long now = Stopwatch.GetTimestamp();
                foreach (var (client, settings) in targets)
                {
                    long interval = Stopwatch.Frequency / Math.Max(1, settings.Fps);
                    if (client.Sending || client.SentHash == lastHash || now - client.LastSentTicks < interval) continue;
                    client.Sending = true;
                    client.SentHash = lastHash;
                    client.LastSentTicks = now;
                    var frame = lastJpeg;
                    _ = Task.Run(async () =>
                    {
                        await client.Connection.SendFrameAsync(frame);
                        client.Sending = false;
                    });
                }
            }

            var elapsedMs = (Stopwatch.GetTimestamp() - started) * 1000 / Stopwatch.Frequency;
            var waitMs = (int)Math.Max(15, 1000 / Math.Max(1, fps) - elapsedMs);
            await Task.Delay(waitMs, token).ContinueWith(_ => { });
        }
    }

    // MARK: State shown to the student and the teacher

    void RefreshState()
    {
        var ready = ReadyClients();
        bool controlled = ready.Any(c => c.ControlEnabled);
        bool watchingLive = ready.Any(c => c.Stream?.Live == true);
        bool viewed = ready.Any(c => c.Stream != null);

        tray.Icon = viewed ? viewedIcon : normalIcon;
        var tip = controlled ? "Your teacher is controlling this PC" : viewed ? "Your teacher can see this screen" : "TP Classroom Student";
        tray.Text = tip.Length > 60 ? tip[..60] : tip;

        if (controlled) banner.SetPersistent("Your teacher is controlling this PC", Color.FromArgb(216, 38, 51));
        else if (watchingLive) banner.SetPersistent("Your teacher is viewing your screen", Color.FromArgb(216, 115, 13));
        else banner.SetPersistent(null, Color.Empty);
    }

    NetMessage MakeInfo() => new()
    {
        Type = "info", Id = AppInfo.DeviceId, Name = config.StudentName, User = AppInfo.UserName,
        Computer = AppInfo.ComputerName, Os = "windows", Version = AppInfo.Version,
        ScreenOk = capture.LastCaptureOk, ControlOk = true, Locked = lockScreen.IsLocked,
    };

    void SendInfoToAll()
    {
        var info = MakeInfo();
        foreach (var client in ReadyClients()) _ = client.Connection.SendAsync(info);
    }

    void NotifyAll(string text)
    {
        foreach (var client in ReadyClients()) _ = client.Connection.SendAsync(NetMessage.Notice(text));
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            stopping.Cancel();
            tray.Visible = false;
            tray.Dispose();
            listener?.Stop();
            discovery?.Dispose();
            lockScreen.Unlock();
            banner.Dispose();
        }
        base.Dispose(disposing);
    }
}
