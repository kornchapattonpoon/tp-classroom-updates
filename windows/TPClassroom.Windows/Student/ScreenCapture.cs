using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace TPClassroom.Student;

/// <summary>Captures the main screen (with the mouse pointer) as a JPEG. Skips unchanged screens.</summary>
sealed class ScreenCapture
{
    static readonly ImageCodecInfo JpegCodec =
        ImageCodecInfo.GetImageEncoders().First(c => c.FormatID == ImageFormat.Jpeg.Guid);

    public bool LastCaptureOk { get; private set; } = true;

    /// <summary>Returns (null, hash) if the screen looks the same as last time.</summary>
    public (byte[]? Jpeg, int Hash) Capture(int maxWidth, double quality, int previousHash)
    {
        try
        {
            var bounds = Screen.PrimaryScreen?.Bounds ?? new Rectangle(0, 0, 1920, 1080);
            using var full = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format24bppRgb);
            using (var g = Graphics.FromImage(full))
            {
                g.CopyFromScreen(bounds.Location, Point.Empty, bounds.Size, CopyPixelOperation.SourceCopy);
                DrawCursor(g, bounds);
            }

            double scale = Math.Min(1.0, (double)maxWidth / Math.Max(1, bounds.Width));
            int width = Math.Max(2, (int)(bounds.Width * scale));
            int height = Math.Max(2, (int)(bounds.Height * scale));
            using var small = new Bitmap(width, height, PixelFormat.Format24bppRgb);
            using (var g = Graphics.FromImage(small))
            {
                g.InterpolationMode = InterpolationMode.HighQualityBilinear;
                g.DrawImage(full, 0, 0, width, height);
            }

            int hash = Hash(small);
            LastCaptureOk = true;
            if (hash == previousHash) return (null, hash);

            using var output = new MemoryStream();
            using var parameters = new EncoderParameters(1);
            parameters.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality,
                                                       (long)Math.Clamp(quality * 100, 10, 95));
            small.Save(output, JpegCodec, parameters);
            return (output.ToArray(), hash);
        }
        catch
        {
            // e.g. the screen is on the secure desktop (UAC prompt, lock screen).
            LastCaptureOk = false;
            return (null, previousHash);
        }
    }

    static int Hash(Bitmap bitmap)
    {
        var data = bitmap.LockBits(new Rectangle(0, 0, bitmap.Width, bitmap.Height),
                                   ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
        try
        {
            int length = Math.Abs(data.Stride) * bitmap.Height;
            var bytes = new byte[length];
            Marshal.Copy(data.Scan0, bytes, 0, length);
            var hash = new HashCode();
            hash.AddBytes(bytes);
            return hash.ToHashCode();
        }
        finally
        {
            bitmap.UnlockBits(data);
        }
    }

    static void DrawCursor(Graphics g, Rectangle bounds)
    {
        var info = new Native.CURSORINFO { cbSize = Marshal.SizeOf<Native.CURSORINFO>() };
        if (!Native.GetCursorInfo(ref info) || (info.flags & Native.CURSOR_SHOWING) == 0) return;
        int hotX = 0, hotY = 0;
        if (Native.GetIconInfo(info.hCursor, out var icon))
        {
            hotX = icon.xHotspot;
            hotY = icon.yHotspot;
            if (icon.hbmMask != IntPtr.Zero) Native.DeleteObject(icon.hbmMask);
            if (icon.hbmColor != IntPtr.Zero) Native.DeleteObject(icon.hbmColor);
        }
        var hdc = g.GetHdc();
        try
        {
            Native.DrawIconEx(hdc, info.ptScreenPos.X - bounds.Left - hotX, info.ptScreenPos.Y - bounds.Top - hotY,
                              info.hCursor, 0, 0, 0, IntPtr.Zero, Native.DI_NORMAL);
        }
        finally
        {
            g.ReleaseHdc(hdc);
        }
    }
}
