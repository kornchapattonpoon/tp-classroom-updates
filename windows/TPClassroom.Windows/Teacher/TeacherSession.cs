using TPClassroom.Core;

namespace TPClassroom.Teacher;

enum SessionStatus
{
    Offline,
    Connecting,
    Online,
    Error,
}

/// <summary>A computer the teacher has seen before (saved, so the list survives quitting and restarting).</summary>
sealed class KnownStudent
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string User { get; set; } = "";
    public string Os { get; set; } = "windows";
    public string Version { get; set; } = "";
    public string Host { get; set; } = "";
    public int Port { get; set; } = Ports.Tcp;
    public DateTime LastSeen { get; set; }
}

/// <summary>The teacher's connection to one student computer (Mac or Windows).</summary>
sealed class TeacherSession
{
    readonly TeacherContext owner;
    SecureConnection? connection;
    int generation;
    bool lockRequested;
    string lockMessage = "";
    int liveViewers;
    StreamSettings? sentStream;
    DateTime nextAttempt = DateTime.MinValue;
    double retryDelay = 2;
    string? updateSentForVersion;

    public TeacherSession(KnownStudent known, TeacherContext owner)
    {
        this.owner = owner;
        Id = known.Id;
        Name = known.Name;
        User = known.User;
        Os = known.Os;
        Version = known.Version;
        Host = known.Host;
        Port = known.Port;
        LastSeen = known.LastSeen;
    }

    public string Id { get; set; }
    public string Name { get; private set; }
    public string User { get; private set; }
    public string Os { get; private set; }
    public string Version { get; private set; }
    public string Host { get; private set; }
    public int Port { get; private set; }
    public DateTime LastSeen { get; private set; }

    public SessionStatus Status { get; private set; } = SessionStatus.Offline;
    public string? Error { get; private set; }
    public bool ScreenOk { get; private set; } = true;
    public bool ControlOk { get; private set; } = true;
    public bool LockedOnStudent { get; private set; }
    public Image? Frame { get; private set; }
    public bool ControlEnabled { get; private set; }
    public string? Notice { get; set; }
    public double? UpdateProgress { get; private set; }

    public bool IsOnline => Status == SessionStatus.Online;
    public bool IsLocked => IsOnline ? LockedOnStudent : lockRequested;
    public bool IsWindows => Os == "windows";

    /// <summary>Name, status or anything else shown on the tile changed.</summary>
    public event Action? Changed;
    /// <summary>A new screen picture arrived.</summary>
    public event Action? FrameChanged;

    public KnownStudent Known => new()
    {
        Id = Id, Name = Name, User = User, Os = Os, Version = Version, Host = Host, Port = Port, LastSeen = LastSeen,
    };

    public string Subtitle
    {
        get
        {
            var parts = new List<string>();
            if (!string.IsNullOrEmpty(User)) parts.Add(User);
            if (!string.IsNullOrEmpty(Version)) parts.Add("v" + Version);
            if (UpdateProgress is double progress) parts.Add($"Updating {progress:P0}");
            else if (Status == SessionStatus.Connecting) parts.Add("Connecting…");
            else if (Status == SessionStatus.Offline) parts.Add("Offline (remembered)");
            else if (Status == SessionStatus.Error) parts.Add("Can't connect");
            return string.Join(" · ", parts);
        }
    }

    public string? Warning
    {
        get
        {
            if (Status == SessionStatus.Error) return Error;
            if (IsOnline && !ScreenOk) return IsWindows ? "Can't capture this screen right now." : "Screen Recording isn't allowed on this Mac yet.";
            if (IsOnline && !ControlOk) return "Remote control isn't allowed on this Mac yet (Accessibility).";
            return Notice;
        }
    }

    void RaiseChanged() => Changed?.Invoke();

    // MARK: Connecting

    public void UpdateFromBeacon(DiscoveryPacket packet, string host)
    {
        if (!string.IsNullOrEmpty(packet.Name)) Name = packet.Name;
        if (packet.User != null) User = packet.User;
        if (packet.Os != null) Os = packet.Os;
        if (packet.Version != null) Version = packet.Version;
        int port = packet.Port ?? Ports.Tcp;
        if (host != Host || port != Port)
        {
            Host = host;
            Port = port;
            nextAttempt = DateTime.MinValue;
            if (!IsOnline) Disconnect(keepStatus: true);
        }
        LastSeen = DateTime.Now;
        RaiseChanged();
    }

    public void ConnectIfIdle()
    {
        if (Status == SessionStatus.Online || Status == SessionStatus.Connecting) return;
        if (DateTime.Now < nextAttempt || string.IsNullOrEmpty(Host)) return;
        Connect();
    }

    public async void Connect()
    {
        if (string.IsNullOrEmpty(Host) || owner.ClassKey == null) return;
        Disconnect(keepStatus: true);
        int my = ++generation;
        Status = SessionStatus.Connecting;
        RaiseChanged();
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(8));
            var newConnection = await SecureConnection.ConnectAsync(Host, Port, owner.ClassKey, timeout.Token);
            if (my != generation)
            {
                newConnection.Cancel();
                return;
            }
            connection = newConnection;
            newConnection.MessageReceived += message => { if (connection == newConnection) Handle(message); };
            newConnection.FrameReceived += bytes => { if (connection == newConnection) HandleFrame(bytes); };
            newConnection.Closed += reason => { if (connection == newConnection) ConnectionClosed(reason); };
            newConnection.Start();
            await newConnection.SendAsync(NetMessage.Hello(owner.Config.TeacherDisplayName));
        }
        catch (Exception ex)
        {
            if (my != generation) return;
            Status = SessionStatus.Error;
            Error = ex is OperationCanceledException ? "The connection timed out." :
                    ex is System.Net.Sockets.SocketException ? "TP Classroom isn't reachable on that computer right now." : ex.Message;
            nextAttempt = DateTime.Now.AddSeconds(retryDelay);
            retryDelay = Math.Min(retryDelay * 2, 30);
            RaiseChanged();
        }
    }

    public void Disconnect(bool keepStatus = false)
    {
        generation++;
        connection?.Cancel();
        connection = null;
        ControlEnabled = false;
        sentStream = null;
        UpdateProgress = null;
        if (!keepStatus) Status = SessionStatus.Offline;
        RaiseChanged();
    }

    void ConnectionClosed(string? reason)
    {
        bool wasOnline = IsOnline;
        connection = null;
        ControlEnabled = false;
        sentStream = null;
        UpdateProgress = null;
        if (reason != null && !wasOnline)
        {
            Status = SessionStatus.Error;
            Error = reason;
        }
        else
        {
            Status = SessionStatus.Offline;
        }
        nextAttempt = DateTime.Now.AddSeconds(retryDelay);
        retryDelay = Math.Min(retryDelay * 2, 30);
        RaiseChanged();
        owner.SessionStatusChanged();
    }

    // MARK: Incoming

    void Handle(NetMessage message)
    {
        switch (message.Type)
        {
            case "info":
                bool wasOnline = IsOnline;
                if (!string.IsNullOrEmpty(message.Id) && message.Id != Id)
                {
                    owner.StudentChangedId(this, message.Id);
                    Id = message.Id;
                }
                if (!string.IsNullOrEmpty(message.Name)) Name = message.Name;
                if (message.User != null) User = message.User;
                if (message.Os != null) Os = message.Os;
                if (message.Version != null) Version = message.Version;
                ScreenOk = message.ScreenOk ?? true;
                ControlOk = message.ControlOk ?? true;
                LockedOnStudent = message.Locked ?? false;
                LastSeen = DateTime.Now;
                Status = SessionStatus.Online;
                retryDelay = 2;
                if (!wasOnline)
                {
                    Notice = null;
                    sentStream = null;
                    RefreshStream();
                    if (lockRequested) _ = connection?.SendAsync(new NetMessage { Type = "lock", Text = lockMessage });
                }
                RaiseChanged();
                owner.StudentInfoChanged(this, !wasOnline);
                break;
            case "notice":
                Notice = message.Text;
                RaiseChanged();
                break;
        }
    }

    void HandleFrame(byte[] bytes)
    {
        Image? image;
        try
        {
            using var stream = new MemoryStream(bytes);
            using var decoded = Image.FromStream(stream);
            image = new Bitmap(decoded);
        }
        catch
        {
            return;
        }
        var old = Frame;
        Frame = image;
        FrameChanged?.Invoke();
        old?.Dispose();
    }

    // MARK: Commands

    public void Send(NetMessage message)
    {
        if (IsOnline) _ = connection?.SendAsync(message);
    }

    public void OpenLiveView()
    {
        liveViewers++;
        RefreshStream();
    }

    public void CloseLiveView()
    {
        liveViewers = Math.Max(0, liveViewers - 1);
        if (liveViewers == 0 && ControlEnabled) SetControl(false);
        RefreshStream();
    }

    public void RefreshStream()
    {
        if (!IsOnline) return;
        var desired = liveViewers > 0 ? owner.LiveSettings : StreamSettings.Thumbnail;
        if (desired == sentStream) return;
        sentStream = desired;
        _ = connection?.SendAsync(NetMessage.Stream(desired));
    }

    public void SetControl(bool enabled)
    {
        ControlEnabled = enabled && IsOnline;
        _ = connection?.SendAsync(new NetMessage { Type = "control", Enabled = ControlEnabled });
        RaiseChanged();
    }

    public void SendInput(InputEvent input)
    {
        if (ControlEnabled) _ = connection?.SendAsync(new NetMessage { Type = "input", Input = input });
    }

    public void Lock(string message)
    {
        lockRequested = true;
        lockMessage = message;
        _ = connection?.SendAsync(new NetMessage { Type = "lock", Text = message });
        RaiseChanged();
    }

    public void Unlock()
    {
        lockRequested = false;
        _ = connection?.SendAsync(new NetMessage { Type = "unlock" });
        RaiseChanged();
    }

    // MARK: Actions for TP AI

    /// <summary>
    /// Sends mouse/keyboard events even if Control is off: Control is switched on just for these
    /// events (the student sees the "controlling" banner), then back off.
    /// </summary>
    public async Task PerformAiInputAsync(IEnumerable<InputEvent> events)
    {
        var current = connection;
        if (!IsOnline || current == null) return;
        bool wasOn = ControlEnabled;
        if (!wasOn) await current.SendAsync(new NetMessage { Type = "control", Enabled = true });
        foreach (var input in events) await current.SendAsync(new NetMessage { Type = "input", Input = input });
        if (!wasOn) await current.SendAsync(new NetMessage { Type = "control", Enabled = false });
    }

    public async Task TypeTextAsAiAsync(string text)
    {
        var current = connection;
        if (!IsOnline || current == null) return;
        bool wasOn = ControlEnabled;
        if (!wasOn) await current.SendAsync(new NetMessage { Type = "control", Enabled = true });
        await current.SendAsync(new NetMessage { Type = "typeText", Text = text });
        if (!wasOn) await current.SendAsync(new NetMessage { Type = "control", Enabled = false });
    }

    public void Power(string action) => Send(new NetMessage { Type = "power", Action = action });

    // MARK: Pushing updates (same version as the teacher, works offline)

    public async void SendUpdate(byte[] data, PackageInfo info)
    {
        var current = connection;
        if (!IsOnline || UpdateProgress != null || updateSentForVersion == info.Version || current == null) return;
        updateSentForVersion = info.Version;
        UpdateProgress = 0;
        RaiseChanged();
        info.Size = data.Length;
        if (!await current.SendAsync(NetMessage.UpdateBegin(info))) { UpdateProgress = null; RaiseChanged(); return; }
        const int chunkSize = 512 * 1024;
        for (int offset = 0; offset < data.Length; offset += chunkSize)
        {
            if (connection != current) { UpdateProgress = null; RaiseChanged(); return; }
            var chunk = data.AsSpan(offset, Math.Min(chunkSize, data.Length - offset)).ToArray();
            if (!await current.SendChunkAsync(chunk)) { UpdateProgress = null; RaiseChanged(); return; }
            UpdateProgress = (double)(offset + chunk.Length) / data.Length;
            RaiseChanged();
        }
        await current.SendAsync(new NetMessage { Type = "updateEnd" });
        UpdateProgress = null;
        RaiseChanged();
    }
}
