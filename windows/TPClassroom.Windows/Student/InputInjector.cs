using System.Runtime.InteropServices;
using TPClassroom.Core;

namespace TPClassroom.Student;

/// <summary>Turns the teacher's mouse and keyboard events into real input on this PC.</summary>
static class InputInjector
{
    public static void Post(InputEvent e)
    {
        double x = Math.Clamp(e.X ?? 0.5, 0, 1);
        double y = Math.Clamp(e.Y ?? 0.5, 0, 1);
        int button = e.Button ?? 0;

        switch (e.Kind)
        {
            case "move":
            case "drag":
                Mouse(Native.MOUSEEVENTF_MOVE | Native.MOUSEEVENTF_ABSOLUTE, x, y, 0);
                break;
            case "down":
                Mouse(Native.MOUSEEVENTF_MOVE | Native.MOUSEEVENTF_ABSOLUTE | ButtonFlag(button, true), x, y, 0);
                break;
            case "up":
                Mouse(Native.MOUSEEVENTF_MOVE | Native.MOUSEEVENTF_ABSOLUTE | ButtonFlag(button, false), x, y, 0);
                break;
            case "scroll":
                // 40 pixels ≈ one wheel notch (120).
                int vertical = (int)Math.Round((e.Dy ?? 0) * 3);
                int horizontal = (int)Math.Round((e.Dx ?? 0) * 3);
                if (vertical != 0) Wheel(Native.MOUSEEVENTF_WHEEL, vertical);
                if (horizontal != 0) Wheel(Native.MOUSEEVENTF_HWHEEL, -horizontal);
                break;
            case "key":
                if (e.Code != null && KeyMap.TryGetVk(e.Code, out var vk, out var extended))
                    Key(vk, extended, e.Down ?? true);
                break;
        }
    }

    /// <summary>Types text exactly as written (any language), whatever keyboard layout is selected.</summary>
    public static void TypeText(string text)
    {
        var copy = text;
        Task.Run(() =>
        {
            foreach (char c in copy)
            {
                if (c == '\n' || c == '\t')
                {
                    ushort vk = c == '\t' ? (ushort)0x09 : (ushort)0x0D;
                    Key(vk, false, true);
                    Key(vk, false, false);
                }
                else if (c != '\r')
                {
                    UnicodeChar(c, true);
                    UnicodeChar(c, false);
                }
                Thread.Sleep(5);
            }
        });
    }

    static void UnicodeChar(char c, bool down)
    {
        var input = new Native.INPUT { type = Native.INPUT_KEYBOARD };
        input.u.ki = new Native.KEYBDINPUT
        {
            wVk = 0,
            wScan = c,
            dwFlags = Native.KEYEVENTF_UNICODE | (down ? 0u : Native.KEYEVENTF_KEYUP),
        };
        Send(input);
    }

    static uint ButtonFlag(int button, bool down) => button switch
    {
        1 => down ? Native.MOUSEEVENTF_RIGHTDOWN : Native.MOUSEEVENTF_RIGHTUP,
        2 => down ? Native.MOUSEEVENTF_MIDDLEDOWN : Native.MOUSEEVENTF_MIDDLEUP,
        _ => down ? Native.MOUSEEVENTF_LEFTDOWN : Native.MOUSEEVENTF_LEFTUP,
    };

    static void Mouse(uint flags, double x, double y, uint data)
    {
        var input = new Native.INPUT { type = Native.INPUT_MOUSE };
        input.u.mi = new Native.MOUSEINPUT
        {
            dx = (int)Math.Round(x * 65535),
            dy = (int)Math.Round(y * 65535),
            mouseData = data,
            dwFlags = flags,
        };
        Send(input);
    }

    static void Wheel(uint flag, int delta)
    {
        var input = new Native.INPUT { type = Native.INPUT_MOUSE };
        input.u.mi = new Native.MOUSEINPUT { mouseData = unchecked((uint)delta), dwFlags = flag };
        Send(input);
    }

    static void Key(ushort vk, bool extended, bool down)
    {
        uint flags = 0;
        if (extended) flags |= Native.KEYEVENTF_EXTENDEDKEY;
        if (!down) flags |= Native.KEYEVENTF_KEYUP;
        var input = new Native.INPUT { type = Native.INPUT_KEYBOARD };
        input.u.ki = new Native.KEYBDINPUT
        {
            wVk = vk,
            wScan = (ushort)Native.MapVirtualKey(vk, 0),
            dwFlags = flags,
        };
        Send(input);
    }

    static void Send(Native.INPUT input) =>
        Native.SendInput(1, new[] { input }, Marshal.SizeOf<Native.INPUT>());
}
