using System.Drawing.Drawing2D;

namespace TPClassroom.Student;

/// <summary>
/// TP AI's own pointer, drawn above everything on the student's screen while the AI clicks and types,
/// so the student can see exactly what the AI is doing. It never takes clicks or keyboard focus,
/// and it hides by itself after a few seconds.
/// </summary>
sealed class AiCursorForm : Form
{
    static readonly Color Clear = Color.FromArgb(255, 1, 254);   // see-through colour
    static readonly Color Purple = Color.FromArgb(112, 82, 255);
    const double MoveMs = 550, RippleMs = 600;

    readonly System.Windows.Forms.Timer animation = new() { Interval = 15 };
    readonly System.Windows.Forms.Timer hideTimer = new() { Interval = 10000 };
    PointF from, to, current = new(0.5f, 0.5f);   // 0…1 across the main screen
    long moveStart, clickStart = -1;
    string? typing;
    bool shown;

    public AiCursorForm()
    {
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        TopMost = true;
        BackColor = Clear;
        TransparencyKey = Clear;
        DoubleBuffered = true;
        animation.Tick += (_, _) => Step();
        hideTimer.Tick += (_, _) => HideCursor();
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= 0x80 | 0x08000000 | 0x20 | 0x80000;  // toolwindow, no-activate, click-through, layered
            return cp;
        }
    }

    public void Handle(string action, double? x, double? y, string? text)
    {
        if (action == "hide")
        {
            HideCursor();
            return;
        }
        var screen = Screen.PrimaryScreen?.Bounds ?? new Rectangle(0, 0, 1920, 1080);
        if (Bounds != screen) Bounds = screen;
        var target = new PointF((float)Math.Clamp(x ?? current.X, 0, 1), (float)Math.Clamp(y ?? current.Y, 0, 1));
        switch (action)
        {
            case "click":
                current = from = to = target;
                clickStart = Environment.TickCount64;
                typing = null;
                break;
            case "type":
                typing = text ?? "";
                break;
            default: // move
                typing = null;
                if (shown)
                {
                    from = current;
                    to = target;
                    moveStart = Environment.TickCount64;
                }
                else
                {
                    current = from = to = target;
                }
                break;
        }
        if (!shown)
        {
            shown = true;
            Show();
        }
        TopMost = true;
        animation.Start();
        hideTimer.Stop();
        hideTimer.Start();
        Invalidate();
    }

    void HideCursor()
    {
        hideTimer.Stop();
        animation.Stop();
        shown = false;
        typing = null;
        clickStart = -1;
        Hide();
    }

    void Step()
    {
        long now = Environment.TickCount64;
        double t = Math.Min(1, (now - moveStart) / MoveMs);
        double eased = t < 0.5 ? 2 * t * t : 1 - Math.Pow(-2 * t + 2, 2) / 2;
        current = new PointF((float)(from.X + (to.X - from.X) * eased), (float)(from.Y + (to.Y - from.Y) * eased));
        if (clickStart >= 0 && now - clickStart >= RippleMs) clickStart = -1;
        Invalidate();
        if (t >= 1 && clickStart < 0) animation.Stop();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.None;   // smooth edges would show the see-through colour as a pink rim
        float s = DeviceDpi / 96f;
        var spot = new PointF(current.X * (ClientSize.Width - 1), current.Y * (ClientSize.Height - 1));

        if (clickStart >= 0)
        {
            double p = Math.Min(1, (Environment.TickCount64 - clickStart) / RippleMs);
            float r = (float)(6 + 40 * p) * s;
            using var ring = new Pen(Color.FromArgb(110, 110, 255), 4 * s);
            g.DrawEllipse(ring, spot.X - r, spot.Y - r, 2 * r, 2 * r);
        }

        float[,] shape = { { 0, 0 }, { 0, 16 }, { 4, 12.5f }, { 7, 19 }, { 9.5f, 18 }, { 6.5f, 11.5f }, { 12, 11.5f } };
        var arrow = new PointF[shape.GetLength(0)];
        for (int i = 0; i < arrow.Length; i++)
            arrow[i] = new PointF(spot.X + shape[i, 0] * 1.7f * s, spot.Y + shape[i, 1] * 1.7f * s);
        using (var fill = new SolidBrush(Purple)) g.FillPolygon(fill, arrow);
        using (var outline = new Pen(Color.White, 2 * s)) g.DrawPolygon(outline, arrow);

        string label = typing == null ? "TP AI"
            : typing.Length == 0 ? "TP AI is typing…"
            : "TP AI is typing: " + Tail(typing.Replace("\r", "").Replace("\n", " ⏎ "), 40);
        using var font = new Font("Segoe UI", 10, FontStyle.Bold);
        var size = g.MeasureString(label, font);
        var box = new RectangleF(spot.X + 22 * s, spot.Y + 30 * s, size.Width + 16 * s, size.Height + 8 * s);
        using (var path = Pill(box))
        {
            using var back = new SolidBrush(Purple);
            using var edge = new Pen(Color.White, 1.5f * s);
            g.FillPath(back, path);
            g.DrawPath(edge, path);
        }
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
        g.DrawString(label, font, Brushes.White, box.X + 8 * s, box.Y + 4 * s);
    }

    static string Tail(string text, int max) => text.Length <= max ? text : "…" + text[^max..];

    static GraphicsPath Pill(RectangleF box)
    {
        float d = box.Height;
        var path = new GraphicsPath();
        path.AddArc(box.X, box.Y, d, d, 90, 180);
        path.AddArc(box.Right - d, box.Y, d, d, 270, 180);
        path.CloseFigure();
        return path;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            animation.Dispose();
            hideTimer.Dispose();
        }
        base.Dispose(disposing);
    }
}
