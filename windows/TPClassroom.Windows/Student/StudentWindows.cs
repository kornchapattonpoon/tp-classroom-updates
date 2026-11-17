using System.Runtime.InteropServices;

namespace TPClassroom.Student;

/// <summary>Covers every screen while the teacher has locked this PC.</summary>
sealed class LockScreen
{
    readonly List<LockForm> forms = new();
    readonly Native.LowLevelKeyboardProc hookProc;
    IntPtr hook = IntPtr.Zero;
    System.Windows.Forms.Timer? keepOnTop;

    public LockScreen()
    {
        hookProc = HookCallback;   // kept in a field so it isn't garbage-collected
    }

    public bool IsLocked => forms.Count > 0;
    public Func<string, bool>? VerifyPin { get; set; }

    public void Lock(string message, string teacher, bool allowAdminUnlock)
    {
        Unlock();
        bool first = true;
        foreach (var screen in Screen.AllScreens)
        {
            var form = new LockForm(message, teacher, allowAdminUnlock && first, pin => VerifyPin?.Invoke(pin) == true);
            form.Bounds = screen.Bounds;
            form.Show();
            forms.Add(form);
            first = false;
        }
        forms.FirstOrDefault()?.Activate();
        hook = Native.SetWindowsHookEx(Native.WH_KEYBOARD_LL, hookProc, Native.GetModuleHandle(null), 0);
        keepOnTop = new System.Windows.Forms.Timer { Interval = 1000 };
        keepOnTop.Tick += (_, _) =>
        {
            foreach (var form in forms) form.TopMost = true;
            if (Form.ActiveForm is not LockForm) forms.FirstOrDefault()?.Activate();
        };
        keepOnTop.Start();
    }

    public void Unlock()
    {
        keepOnTop?.Stop();
        keepOnTop?.Dispose();
        keepOnTop = null;
        if (hook != IntPtr.Zero)
        {
            Native.UnhookWindowsHookEx(hook);
            hook = IntPtr.Zero;
        }
        foreach (var form in forms) form.CloseForReal();
        forms.Clear();
    }

    /// <summary>Blocks Windows key, Alt+Tab, Alt+Esc, Ctrl+Esc and Alt+F4 while locked.</summary>
    IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0 && IsLocked)
        {
            var info = Marshal.PtrToStructure<Native.KBDLLHOOKSTRUCT>(lParam);
            bool alt = (info.flags & Native.LLKHF_ALTDOWN) != 0;
            bool ctrl = (Native.GetAsyncKeyState(0x11) & 0x8000) != 0;
            uint vk = info.vkCode;
            bool block = vk == 0x5B || vk == 0x5C ||                                  // Windows keys
                         (alt && (vk == 0x09 || vk == 0x1B || vk == 0x73)) ||         // Alt+Tab/Esc/F4
                         (ctrl && vk == 0x1B);                                        // Ctrl+Esc
            if (block) return (IntPtr)1;
        }
        return Native.CallNextHookEx(hook, nCode, wParam, lParam);
    }
}

sealed class LockForm : Form
{
    bool allowClose;

    public LockForm(string message, string teacher, bool showAdminUnlock, Func<string, bool> verifyPin)
    {
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        ShowInTaskbar = false;
        BackColor = Color.FromArgb(18, 22, 52);
        ForeColor = Color.White;
        KeyPreview = true;

        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 5, BackColor = Color.Transparent };
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 50));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 50));
        layout.Controls.Add(new Label
        {
            Text = "🔒", Font = new Font("Segoe UI Emoji", 64), AutoSize = true, Anchor = AnchorStyles.None,
        }, 0, 1);
        layout.Controls.Add(new Label
        {
            Text = string.IsNullOrWhiteSpace(message) ? "Eyes on your teacher, please" : message,
            Font = new Font("Segoe UI", 36, FontStyle.Bold), AutoSize = true, Anchor = AnchorStyles.None,
            TextAlign = ContentAlignment.MiddleCenter, MaximumSize = new Size(1400, 0),
        }, 0, 2);
        layout.Controls.Add(new Label
        {
            Text = "Locked by " + teacher, Font = new Font("Segoe UI", 16), AutoSize = true,
            Anchor = AnchorStyles.None, ForeColor = Color.FromArgb(180, 190, 220),
        }, 0, 3);
        Controls.Add(layout);

        if (showAdminUnlock)
        {
            var panel = new FlowLayoutPanel
            {
                AutoSize = true, Anchor = AnchorStyles.Bottom | AnchorStyles.Right, BackColor = Color.Transparent,
                FlowDirection = FlowDirection.LeftToRight, WrapContents = false,
            };
            var pinBox = new TextBox { UseSystemPasswordChar = true, Width = 140, Visible = false };
            var unlock = new Button { Text = "Unlock", AutoSize = true, Visible = false, ForeColor = Color.Black, BackColor = Color.White };
            var admin = new LinkLabel { Text = "Admin", AutoSize = true, LinkColor = Color.FromArgb(110, 120, 160) };
            admin.LinkClicked += (_, _) => { pinBox.Visible = true; unlock.Visible = true; admin.Visible = false; pinBox.Focus(); };
            void TryUnlock()
            {
                if (!verifyPin(pinBox.Text)) { pinBox.Text = ""; pinBox.BackColor = Color.MistyRose; }
            }
            unlock.Click += (_, _) => TryUnlock();
            pinBox.KeyDown += (_, e) => { if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; TryUnlock(); } };
            panel.Controls.Add(pinBox);
            panel.Controls.Add(unlock);
            panel.Controls.Add(admin);
            Controls.Add(panel);
            panel.BringToFront();
            Resize += (_, _) => panel.Location = new Point(ClientSize.Width - panel.Width - 24, ClientSize.Height - panel.Height - 24);
        }
    }

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= 0x80;   // WS_EX_TOOLWINDOW: not in Alt+Tab
            return cp;
        }
    }

    public void CloseForReal()
    {
        allowClose = true;
        Close();
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (!allowClose && e.CloseReason == CloseReason.UserClosing) e.Cancel = true;
        base.OnFormClosing(e);
    }
}

/// <summary>A small coloured pill at the top of the screen. Clicks pass through it.</summary>
sealed class BannerForm : Form
{
    readonly Label label;
    readonly System.Windows.Forms.Timer flashTimer = new();
    (string Text, Color Color)? persistent;

    public BannerForm()
    {
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        TopMost = true;
        Opacity = 0.93;
        Padding = new Padding(16, 8, 16, 8);
        label = new Label { AutoSize = true, ForeColor = Color.White, Font = new Font("Segoe UI", 10, FontStyle.Bold) };
        Controls.Add(label);
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        flashTimer.Tick += (_, _) => { flashTimer.Stop(); Render(persistent); };
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= 0x80 | 0x08000000 | 0x20 | 0x80000;  // toolwindow, no-activate, transparent, layered
            return cp;
        }
    }

    public void SetPersistent(string? text, Color color)
    {
        persistent = text == null ? null : (text, color);
        if (!flashTimer.Enabled) Render(persistent);
    }

    public void Flash(string text, int seconds = 6)
    {
        Render((text, Color.FromArgb(52, 90, 216)));
        flashTimer.Stop();
        flashTimer.Interval = seconds * 1000;
        flashTimer.Start();
    }

    void Render((string Text, Color Color)? content)
    {
        if (content == null)
        {
            Hide();
            return;
        }
        label.Text = content.Value.Text;
        BackColor = content.Value.Color;
        if (!Visible) Show();
        PerformLayout();
        var area = Screen.PrimaryScreen?.WorkingArea ?? new Rectangle(0, 0, 1280, 800);
        Location = new Point(area.Left + (area.Width - Width) / 2, area.Top + 10);
        TopMost = true;
    }
}

/// <summary>A message from the teacher, floating above other windows.</summary>
sealed class MessageForm : Form
{
    public MessageForm(string text, string teacher)
    {
        Text = "Message from " + teacher;
        TopMost = true;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(440, 200);
        var body = new Label
        {
            Text = text, Font = new Font("Segoe UI", 14), Dock = DockStyle.Fill, Padding = new Padding(16),
        };
        var ok = new Button { Text = "OK", Dock = DockStyle.Bottom, Height = 40, DialogResult = DialogResult.OK };
        ok.Click += (_, _) => Close();
        Controls.Add(body);
        Controls.Add(ok);
        AcceptButton = ok;
    }
}

/// <summary>Asks for the admin PIN.</summary>
static class PinPrompt
{
    public static bool Ask(string reason, Func<string, bool> verify)
    {
        using var form = new Form
        {
            Text = "Admin PIN required", FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false,
            MinimizeBox = false, StartPosition = FormStartPosition.CenterScreen, ClientSize = new Size(360, 140), TopMost = true,
        };
        var label = new Label { Text = reason, Location = new Point(12, 12), Size = new Size(336, 40) };
        var box = new TextBox { UseSystemPasswordChar = true, Location = new Point(12, 56), Width = 336 };
        var ok = new Button { Text = "OK", DialogResult = DialogResult.OK, Location = new Point(192, 96), Width = 75 };
        var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Location = new Point(273, 96), Width = 75 };
        form.Controls.AddRange(new Control[] { label, box, ok, cancel });
        form.AcceptButton = ok;
        form.CancelButton = cancel;
        if (form.ShowDialog() != DialogResult.OK) return false;
        if (verify(box.Text)) return true;
        MessageBox.Show("Wrong PIN", "TP Classroom", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        return false;
    }
}
