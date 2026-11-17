namespace TPClassroom.Teacher;

/// <summary>One student in the grid: live thumbnail, name and status.</summary>
sealed class StudentTile : UserControl
{
    readonly TeacherSession session;
    readonly PictureBox picture = new()
    {
        Dock = DockStyle.Top, Height = 158, SizeMode = PictureBoxSizeMode.Zoom, BackColor = Color.Black,
    };
    readonly Label placeholder = new()
    {
        Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter, ForeColor = Color.Gainsboro, BackColor = Color.Transparent,
    };
    readonly Panel header = new() { Dock = DockStyle.Top, Height = 24 };
    readonly Label dot = new() { Dock = DockStyle.Left, Width = 18, Text = "●", Font = new Font("Segoe UI", 11), TextAlign = ContentAlignment.MiddleLeft };
    readonly Label nameLabel = new() { Dock = DockStyle.Fill, Font = new Font("Segoe UI", 10.5f, FontStyle.Bold), TextAlign = ContentAlignment.MiddleLeft, AutoEllipsis = true };
    readonly Label subtitleLabel = new() { AutoSize = false, Height = 20, Dock = DockStyle.Top, AutoEllipsis = true };
    readonly ToolTip toolTip = new();

    public event Action? OpenRequested;

    public StudentTile(TeacherSession session)
    {
        this.session = session;
        Size = new Size(280, 222);
        Margin = new Padding(8);
        Padding = new Padding(8);
        BackColor = Color.White;
        Cursor = Cursors.Hand;

        picture.Controls.Add(placeholder);
        header.Controls.Add(nameLabel);
        header.Controls.Add(dot);
        Controls.Add(subtitleLabel);
        Controls.Add(header);
        Controls.Add(picture);

        foreach (Control control in new Control[] { this, picture, placeholder, header, dot, nameLabel, subtitleLabel })
            control.Click += (_, _) => OpenRequested?.Invoke();

        session.Changed += OnChanged;
        session.FrameChanged += OnFrame;
        OnChanged();
        OnFrame();
    }

    void OnChanged()
    {
        if (IsDisposed) return;
        dot.ForeColor = session.Status switch
        {
            SessionStatus.Online => Color.FromArgb(40, 180, 80),
            SessionStatus.Connecting => Color.Goldenrod,
            SessionStatus.Error => Color.Firebrick,
            _ => Color.Silver,
        };
        nameLabel.Text = (session.IsWindows ? "" : "Mac · ") + session.Name;

        var warning = session.Warning;
        if (session.IsLocked)
        {
            subtitleLabel.Text = "LOCKED · " + session.Subtitle;
            subtitleLabel.ForeColor = Color.Firebrick;
        }
        else if (warning != null)
        {
            subtitleLabel.Text = "Warning: " + warning;
            subtitleLabel.ForeColor = Color.DarkOrange;
        }
        else
        {
            subtitleLabel.Text = session.Subtitle;
            subtitleLabel.ForeColor = Color.DimGray;
        }
        var tip = warning ?? "Click to watch and help " + session.Name;
        toolTip.SetToolTip(nameLabel, tip);
        toolTip.SetToolTip(picture, tip);
        toolTip.SetToolTip(subtitleLabel, tip);

        placeholder.Visible = !session.IsOnline || session.Frame == null;
        placeholder.Text = session.Status switch
        {
            SessionStatus.Online => session.ScreenOk ? "Waiting for screen…" : "Screen can't be shown yet",
            SessionStatus.Connecting => "Connecting…",
            SessionStatus.Error => session.Error ?? "Can't connect",
            _ => "Offline (remembered)",
        };
        if (!session.IsOnline) picture.Image = null;
    }

    void OnFrame()
    {
        if (IsDisposed || !session.IsOnline) return;
        picture.Image = session.Frame;
        placeholder.Visible = session.Frame == null;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            session.Changed -= OnChanged;
            session.FrameChanged -= OnFrame;
            picture.Image = null;
            toolTip.Dispose();
        }
        base.Dispose(disposing);
    }
}
