using System.Drawing.Drawing2D;
using System.Drawing.Text;

namespace TPClassroom.Teacher;

/// <summary>Draws TP AI's pointer (and its "TP AI" tag) over a student's screen in the live window.</summary>
static class AiPointerPainter
{
    static readonly Color Purple = Color.FromArgb(112, 82, 255);
    static readonly Color Blue = Color.FromArgb(51, 140, 255);
    static readonly float[,] Arrow = { { 0, 0 }, { 0, 16 }, { 4, 12.5f }, { 7, 19 }, { 9.5f, 18 }, { 6.5f, 11.5f }, { 12, 11.5f } };

    /// <param name="ripple">0…1 while a click ripple grows, or -1 for none.</param>
    public static void Paint(Graphics g, PointF spot, string? typing, double ripple, float scale)
    {
        var smoothing = g.SmoothingMode;
        g.SmoothingMode = SmoothingMode.AntiAlias;

        if (ripple >= 0)
        {
            float r = (float)(6 + 40 * ripple) * scale;
            int alpha = (int)(230 * (1 - ripple));
            using var ring = new Pen(Color.FromArgb(alpha, 110, 110, 255), 4 * scale);
            g.DrawEllipse(ring, spot.X - r, spot.Y - r, 2 * r, 2 * r);
        }

        var points = new PointF[Arrow.GetLength(0)];
        for (int i = 0; i < points.Length; i++)
            points[i] = new PointF(spot.X + Arrow[i, 0] * 1.6f * scale, spot.Y + Arrow[i, 1] * 1.6f * scale);
        var bounds = new RectangleF(spot.X, spot.Y, 12 * 1.6f * scale + 1, 19 * 1.6f * scale + 1);
        using (var fill = new LinearGradientBrush(bounds, Purple, Blue, 45f)) g.FillPolygon(fill, points);
        using (var outline = new Pen(Color.White, 2 * scale)) g.DrawPolygon(outline, points);

        string label = typing == null ? "TP AI"
            : typing.Length == 0 ? "TP AI is typing…"
            : "TP AI is typing: " + Tail(typing.Replace("\r", "").Replace("\n", " ⏎ "), 40);
        using var font = new Font("Segoe UI", 9.5f, FontStyle.Bold);
        var size = g.MeasureString(label, font);
        var box = new RectangleF(spot.X + 20 * scale, spot.Y + 28 * scale, size.Width + 14 * scale, size.Height + 6 * scale);
        using (var path = Pill(box))
        using (var back = new LinearGradientBrush(box, Purple, Blue, 0f))
        using (var edge = new Pen(Color.White, 1.5f * scale))
        {
            g.FillPath(back, path);
            g.DrawPath(edge, path);
        }
        var hint = g.TextRenderingHint;
        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        g.DrawString(label, font, Brushes.White, box.X + 7 * scale, box.Y + 3 * scale);
        g.TextRenderingHint = hint;
        g.SmoothingMode = smoothing;
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
}
