using TPClassroom.Core;

namespace TPClassroom.Teacher;

/// <summary>The teacher's main window: a live grid of every student screen.</summary>
sealed class MainForm : Form
{
    readonly TeacherContext context;
    readonly FlowLayoutPanel grid = new() { Dock = DockStyle.Fill, AutoScroll = true, Padding = new Padding(12), BackColor = Color.FromArgb(245, 246, 250) };
    readonly Label emptyLabel = new()
    {
        Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter, Font = new Font("Segoe UI", 13),
        ForeColor = Color.DimGray,
        Text = "Waiting for students…\n\nStudent computers on this network with the same class code appear here by themselves.\nNo internet or IP addresses needed. Once they've appeared, they're remembered.",
    };
    readonly ToolStripStatusLabel statusLabel = new() { Spring = true, TextAlign = ContentAlignment.MiddleLeft };
    readonly ToolStripStatusLabel versionLabel = new();
    readonly ToolStripLabel countLabel = new() { Font = new Font("Segoe UI", 10, FontStyle.Bold) };
    readonly Dictionary<TeacherSession, StudentTile> tiles = new();
    readonly Dictionary<TeacherSession, LiveForm> liveForms = new();

    public MainForm(TeacherContext context)
    {
        this.context = context;
        Text = "TP Classroom";
        Icon = Program.LoadIcon("teacher.ico");
        Size = new Size(1180, 760);
        MinimumSize = new Size(820, 520);
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Segoe UI", 9.5f);

        var toolbar = new ToolStrip { GripStyle = ToolStripGripStyle.Hidden, Padding = new Padding(8, 4, 8, 4), ImageScalingSize = new Size(20, 20) };
        toolbar.Items.Add(new ToolStripLabel("TP Classroom") { Font = new Font("Segoe UI", 13, FontStyle.Bold) });
        toolbar.Items.Add(countLabel);
        toolbar.Items.Add(new ToolStripSeparator());
        toolbar.Items.Add(MakeButton("Lock All", () =>
        {
            var text = TextPrompt.Ask(this, "Lock every student screen", "Eyes on the teacher, please", true);
            if (text != null) context.LockAll(text);
        }));
        toolbar.Items.Add(MakeButton("Unlock All", context.UnlockAll));
        toolbar.Items.Add(MakeButton("Message All", () =>
        {
            var text = TextPrompt.Ask(this, "Send a message to every student", "", false);
            if (text != null) context.MessageAll(text);
        }));
        toolbar.Items.Add(MakeButton("Open Website", () =>
        {
            var text = TextPrompt.Ask(this, "Open a website on every student computer", "example.com", false);
            if (text != null) context.OpenWebsiteAll(text);
        }));
        toolbar.Items.Add(new ToolStripSeparator());
        var ai = MakeButton("TP AI", context.ShowAi);
        ai.Font = new Font("Segoe UI", 10, FontStyle.Bold);
        ai.ForeColor = Color.MediumPurple;
        ai.ToolTipText = "Ask TP AI to do things for you, like shutting down every computer";
        toolbar.Items.Add(ai);
        var more = new ToolStripDropDownButton("More") { Alignment = ToolStripItemAlignment.Right };
        more.DropDownItems.Add("Reconnect Everyone", null, (_, _) => context.ReconnectAll());
        more.DropDownItems.Add("Connect by Address… (only if a computer doesn't appear)", null, (_, _) =>
        {
            var text = TextPrompt.Ask(this, "Address of the student computer (e.g. 192.168.1.25)", "", false);
            if (text != null) context.AddByAddress(text);
        });
        more.DropDownItems.Add(new ToolStripSeparator());
        more.DropDownItems.Add("Settings…", null, (_, _) => { using var f = new SettingsForm(context); f.ShowDialog(this); });
        more.DropDownItems.Add("Check for Updates", null, async (_, _) => await context.Updater.CheckAsync(true));
        more.DropDownItems.Add("Quit TP Classroom Completely", null, (_, _) => Program.QuitCompletely());
        toolbar.Items.Add(more);

        var statusStrip = new StatusStrip();
        statusStrip.Items.Add(statusLabel);
        statusStrip.Items.Add(versionLabel);

        Controls.Add(grid);
        Controls.Add(emptyLabel);
        Controls.Add(toolbar);
        Controls.Add(statusStrip);

        context.SessionsChanged += RebuildTiles;
        context.StatusChanged += RefreshStatus;
        RebuildTiles();
    }

    static ToolStripButton MakeButton(string text, Action action)
    {
        var button = new ToolStripButton(text) { Font = new Font("Segoe UI", 10) };
        button.Click += (_, _) => action();
        return button;
    }

    void RebuildTiles()
    {
        grid.SuspendLayout();
        foreach (var session in tiles.Keys.Where(s => !context.Sessions.Contains(s)).ToList())
        {
            tiles[session].Dispose();
            tiles.Remove(session);
        }
        grid.Controls.Clear();
        foreach (var session in context.Sessions)
        {
            if (!tiles.TryGetValue(session, out var tile))
            {
                tile = new StudentTile(session);
                tile.OpenRequested += () => OpenLive(session);
                tile.ContextMenuStrip = BuildTileMenu(session);
                tiles[session] = tile;
            }
            grid.Controls.Add(tile);
        }
        grid.ResumeLayout();
        emptyLabel.Visible = context.Sessions.Count == 0;
        grid.Visible = context.Sessions.Count > 0;
        RefreshStatus();
    }

    ContextMenuStrip BuildTileMenu(TeacherSession session)
    {
        var menu = new ContextMenuStrip();
        menu.Opening += (_, _) =>
        {
            menu.Items.Clear();
            menu.Items.Add("Watch && Help", null, (_, _) => OpenLive(session));
            menu.Items.Add(new ToolStripSeparator());
            if (session.IsLocked) menu.Items.Add("Unlock Screen", null, (_, _) => session.Unlock());
            else menu.Items.Add("Lock Screen…", null, (_, _) =>
            {
                var text = TextPrompt.Ask(this, "Lock this student's screen", "Eyes on the teacher, please", true);
                if (text != null) session.Lock(text);
            });
            menu.Items.Add("Send Message…", null, (_, _) =>
            {
                var text = TextPrompt.Ask(this, "Send a message", "", false);
                if (text != null) session.Send(new NetMessage { Type = "message", Text = text });
            });
            menu.Items.Add("Open Website…", null, (_, _) =>
            {
                var url = TeacherContext.NormalizeUrl(TextPrompt.Ask(this, "Open a website on this computer", "example.com", false) ?? "");
                if (url != null) session.Send(new NetMessage { Type = "openUrl", Url = url });
            });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Reconnect", null, (_, _) => session.Connect());
            menu.Items.Add("Forget This Computer", null, (_, _) => context.Forget(session));
        };
        menu.Items.Add("…");   // so Opening fires
        return menu;
    }

    /// <summary>Opens (or shows) a student's live window. Returns it, and whether it was just opened.</summary>
    public (LiveForm Form, bool IsNew) OpenLive(TeacherSession session, bool activate = true)
    {
        if (liveForms.TryGetValue(session, out var existing) && !existing.IsDisposed)
        {
            if (activate) existing.Activate();
            else if (existing.WindowState == FormWindowState.Minimized) existing.WindowState = FormWindowState.Normal;
            return (existing, false);
        }
        var form = new LiveForm(session, context);
        liveForms[session] = form;
        context.LiveSessions.Add(session);
        form.FormClosed += (_, _) =>
        {
            liveForms.Remove(session);
            context.LiveSessions.Remove(session);
            if (context.LiveSessions.Count == 0 && context.Updater.HasPendingUpdate) _ = context.Updater.InstallIfAllowedAsync();
        };
        form.Show();
        return (form, true);
    }

    void RefreshStatus()
    {
        if (IsDisposed) return;
        countLabel.Text = $"   {context.OnlineCount} of {context.Sessions.Count} online";
        statusLabel.Text = context.DiscoveryStatus;
        versionLabel.Text = $"v{AppInfo.Version} · {context.Updater.Status}";
    }

    /// <summary>Closing the window keeps TP Classroom running in the notification area.</summary>
    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (e.CloseReason == CloseReason.UserClosing && !Program.Quitting)
        {
            e.Cancel = true;
            foreach (var form in liveForms.Values.ToList()) form.Close();
            Hide();
            context.ShowBackgroundTipOnce();
            return;
        }
        base.OnFormClosing(e);
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        context.SessionsChanged -= RebuildTiles;
        context.StatusChanged -= RefreshStatus;
        base.OnFormClosed(e);
    }
}
