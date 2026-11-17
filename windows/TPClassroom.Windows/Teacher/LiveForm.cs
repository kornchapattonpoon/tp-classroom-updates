using System.Drawing.Drawing2D;
using TPClassroom.Core;

namespace TPClassroom.Teacher;

/// <summary>One student's screen in real time, with remote control.</summary>
sealed class LiveForm : Form
{
    readonly TeacherSession session;
    readonly RemoteView view = new() { Dock = DockStyle.Fill };
    readonly ToolStripButton controlButton = new("Control") { CheckOnClick = true };
    readonly ToolStripButton lockButton = new("Lock");
    readonly ToolStripLabel stateLabel = new();

    public LiveForm(TeacherSession session, TeacherContext context)
    {
        this.session = session;
        Text = session.Name;
        Icon = Program.LoadIcon("teacher.ico");
        Size = new Size(1180, 780);
        MinimumSize = new Size(640, 440);
        StartPosition = FormStartPosition.CenterScreen;
        KeyPreview = false;

        var toolbar = new ToolStrip { GripStyle = ToolStripGripStyle.Hidden, Padding = new Padding(8, 4, 8, 4) };
        toolbar.Items.Add(new ToolStripLabel(session.Name) { Font = new Font("Segoe UI", 11, FontStyle.Bold) });
        toolbar.Items.Add(stateLabel);
        toolbar.Items.Add(new ToolStripSeparator());
        controlButton.CheckedChanged += (_, _) =>
        {
            session.SetControl(controlButton.Checked);
            view.ControlEnabled = session.ControlEnabled;
            if (view.ControlEnabled) view.Focus();
        };
        toolbar.Items.Add(controlButton);
        lockButton.Click += (_, _) =>
        {
            if (session.IsLocked) session.Unlock();
            else
            {
                var text = TextPrompt.Ask(this, "Lock this student's screen", "Eyes on the teacher, please", true);
                if (text != null) session.Lock(text);
            }
        };
        toolbar.Items.Add(lockButton);
        var message = new ToolStripButton("Message");
        message.Click += (_, _) =>
        {
            var text = TextPrompt.Ask(this, "Send a message", "", false);
            if (text != null) session.Send(new NetMessage { Type = "message", Text = text });
        };
        toolbar.Items.Add(message);
        var website = new ToolStripButton("Open Website");
        website.Click += (_, _) =>
        {
            var url = TeacherContext.NormalizeUrl(TextPrompt.Ask(this, "Open a website on this computer", "example.com", false) ?? "");
            if (url != null) session.Send(new NetMessage { Type = "openUrl", Url = url });
        };
        toolbar.Items.Add(website);

        Controls.Add(view);
        Controls.Add(toolbar);

        view.Input += session.SendInput;
        session.FrameChanged += OnFrame;
        session.Changed += OnChanged;
        session.AiPointerChanged += OnAiPointer;
        session.OpenLiveView();
        OnFrame();
        OnChanged();
    }

    void OnFrame()
    {
        if (!IsDisposed) view.Frame = session.Frame;
    }

    void OnAiPointer()
    {
        if (!IsDisposed) view.SetAiPointer(session.AiPointer);
    }

    void OnChanged()
    {
        if (IsDisposed) return;
        Text = session.Name;
        stateLabel.ForeColor = session.AiControlling ? Color.MediumPurple : SystemColors.ControlText;
        stateLabel.Text = session.AiControlling ? "  TP AI is controlling this computer"
                        : session.ControlEnabled ? "  Controlling — clicks and keys go to this computer"
                        : session.IsOnline ? "  Viewing" : "  " + (session.Warning ?? "Disconnected. Reconnecting…");
        lockButton.Text = session.IsLocked ? "Unlock" : "Lock";
        controlButton.Enabled = session.IsOnline;
        if (controlButton.Checked != session.ControlEnabled) controlButton.Checked = session.ControlEnabled;
        view.ControlEnabled = session.ControlEnabled;
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        session.FrameChanged -= OnFrame;
        session.Changed -= OnChanged;
        session.AiPointerChanged -= OnAiPointer;
        view.Input -= session.SendInput;
        session.CloseLiveView();
        base.OnFormClosed(e);
    }
}

/// <summary>Draws the student's screen and turns mouse/keyboard into InputEvents while Control is on.</summary>
sealed class RemoteView : Control
{
    Image? frame;
    long lastMoveTicks;

    // TP AI's pointer (0…1 across the student's screen), animated between positions.
    const double AiMoveMs = 550, AiRippleMs = 600;
    readonly System.Windows.Forms.Timer aiTimer = new() { Interval = 15 };
    bool aiShown;
    PointF aiFrom, aiTo, aiNow;
    long aiMoveStart, aiClickStart = -1;
    int aiClicks;
    string? aiTyping;

    public RemoteView()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                 ControlStyles.UserPaint | ControlStyles.Selectable | ControlStyles.ResizeRedraw, true);
        BackColor = Color.Black;
        TabStop = true;
        aiTimer.Tick += (_, _) => StepAiPointer();
    }

    public void SetAiPointer(TeacherSession.AiPointerState? pointer)
    {
        long now = Environment.TickCount64;
        if (pointer == null)
        {
            aiShown = false;
            aiTimer.Stop();
            Invalidate();
            return;
        }
        var target = new PointF((float)pointer.X, (float)pointer.Y);
        if (!aiShown)
        {
            aiNow = aiFrom = aiTo = target;
            aiClicks = pointer.Clicks;
            aiShown = true;
        }
        else if (target != aiTo)
        {
            aiFrom = aiNow;
            aiTo = target;
            aiMoveStart = now;
        }
        if (pointer.Clicks != aiClicks)
        {
            aiClicks = pointer.Clicks;
            aiClickStart = now;
        }
        aiTyping = pointer.Typing;
        aiTimer.Start();
        Invalidate();
    }

    void StepAiPointer()
    {
        long now = Environment.TickCount64;
        double t = Math.Min(1, (now - aiMoveStart) / AiMoveMs);
        double eased = t < 0.5 ? 2 * t * t : 1 - Math.Pow(-2 * t + 2, 2) / 2;
        aiNow = new PointF((float)(aiFrom.X + (aiTo.X - aiFrom.X) * eased), (float)(aiFrom.Y + (aiTo.Y - aiFrom.Y) * eased));
        if (aiClickStart >= 0 && now - aiClickStart >= AiRippleMs) aiClickStart = -1;
        Invalidate();
        if (t >= 1 && aiClickStart < 0) aiTimer.Stop();
    }

    [System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
    public bool ControlEnabled { get; set; }
    public event Action<InputEvent>? Input;

    [System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
    public Image? Frame
    {
        get => frame;
        set
        {
            frame = value;
            Invalidate();
        }
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.Clear(Color.Black);
        var image = frame;
        if (image == null)
        {
            TextRenderer.DrawText(e.Graphics, "Waiting for the screen…", Font, ClientRectangle, Color.Gray,
                                  TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
            return;
        }
        try
        {
            e.Graphics.InterpolationMode = InterpolationMode.HighQualityBilinear;
            var rect = ImageRect(image);
            e.Graphics.DrawImage(image, rect);
            if (aiShown)
            {
                var spot = new PointF(rect.Left + aiNow.X * rect.Width, rect.Top + aiNow.Y * rect.Height);
                double ripple = aiClickStart < 0 ? -1 : Math.Min(1, (Environment.TickCount64 - aiClickStart) / AiRippleMs);
                AiPointerPainter.Paint(e.Graphics, spot, aiTyping, ripple, DeviceDpi / 96f);
            }
        }
        catch (ArgumentException)
        {
            // The frame was replaced while drawing; the next paint shows the new one.
        }
    }

    Rectangle ImageRect(Image image)
    {
        double scale = Math.Min((double)ClientSize.Width / image.Width, (double)ClientSize.Height / image.Height);
        int width = (int)(image.Width * scale);
        int height = (int)(image.Height * scale);
        return new Rectangle((ClientSize.Width - width) / 2, (ClientSize.Height - height) / 2, width, height);
    }

    (double X, double Y) Position(Point point)
    {
        var image = frame;
        var rect = image == null ? ClientRectangle : ImageRect(image);
        double x = (point.X - rect.Left) / (double)Math.Max(1, rect.Width);
        double y = (point.Y - rect.Top) / (double)Math.Max(1, rect.Height);
        return (Math.Clamp(x, 0, 1), Math.Clamp(y, 0, 1));
    }

    static int ButtonIndex(MouseButtons button) => button switch
    {
        MouseButtons.Right => 1,
        MouseButtons.Middle => 2,
        _ => 0,
    };

    void Send(InputEvent input)
    {
        if (ControlEnabled) Input?.Invoke(input);
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (!ControlEnabled) return;
        long now = Environment.TickCount64;
        if (now - lastMoveTicks < 12) return;   // about 80 updates a second is plenty
        lastMoveTicks = now;
        var (x, y) = Position(e.Location);
        Send(e.Button == MouseButtons.None ? InputEvent.Move(x, y) : InputEvent.Drag(ButtonIndex(e.Button), x, y));
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        Focus();
        var (x, y) = Position(e.Location);
        Send(InputEvent.Press(ButtonIndex(e.Button), true, x, y, Math.Max(1, e.Clicks)));
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        var (x, y) = Position(e.Location);
        Send(InputEvent.Press(ButtonIndex(e.Button), false, x, y, 1));
    }

    protected override void OnMouseWheel(MouseEventArgs e)
    {
        base.OnMouseWheel(e);
        Send(InputEvent.Scroll(0, e.Delta / 3.0));
    }

    protected override bool IsInputKey(Keys keyData) => ControlEnabled || base.IsInputKey(keyData);

    static int Mods(KeyEventArgs e) =>
        (e.Shift ? Core.Mods.Shift : 0) | (e.Control ? Core.Mods.Control : 0) | (e.Alt ? Core.Mods.Alt : 0) |
        (Control.IsKeyLocked(Keys.CapsLock) ? Core.Mods.CapsLock : 0);

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (!ControlEnabled)
        {
            base.OnKeyDown(e);
            return;
        }
        var code = KeyMap.CodeFromKeys(e.KeyCode);
        if (code != null) Send(InputEvent.Key(code, true, Mods(e)));
        e.Handled = true;
        e.SuppressKeyPress = true;
    }

    protected override void OnKeyUp(KeyEventArgs e)
    {
        if (!ControlEnabled)
        {
            base.OnKeyUp(e);
            return;
        }
        var code = KeyMap.CodeFromKeys(e.KeyCode);
        if (code != null) Send(InputEvent.Key(code, false, Mods(e)));
        e.Handled = true;
    }
}
