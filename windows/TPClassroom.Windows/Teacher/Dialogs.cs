using TPClassroom.Core;

namespace TPClassroom.Teacher;

/// <summary>Small dialog for typing a lock message, a message, a website or an address.</summary>
static class TextPrompt
{
    public static string? Ask(IWin32Window? owner, string title, string defaultText, bool allowEmpty)
    {
        using var form = new Form
        {
            Text = "TP Classroom", FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false,
            StartPosition = FormStartPosition.CenterParent, ClientSize = new Size(420, 130), Font = new Font("Segoe UI", 9.5f),
        };
        var label = new Label { Text = title, Location = new Point(12, 12), Size = new Size(396, 22) };
        var box = new TextBox { Text = defaultText, Location = new Point(12, 40), Width = 396 };
        var ok = new Button { Text = "OK", DialogResult = DialogResult.OK, Location = new Point(252, 86), Width = 75 };
        var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Location = new Point(333, 86), Width = 75 };
        form.Controls.AddRange(new Control[] { label, box, ok, cancel });
        form.AcceptButton = ok;
        form.CancelButton = cancel;
        form.Shown += (_, _) => { box.Focus(); box.SelectAll(); };
        var result = owner == null ? form.ShowDialog() : form.ShowDialog(owner);
        if (result != DialogResult.OK) return null;
        var text = box.Text.Trim();
        return text.Length == 0 && !allowEmpty ? null : text;
    }
}

/// <summary>Teacher settings: class code, name, live quality, start with Windows, updates.</summary>
sealed class SettingsForm : Form
{
    public SettingsForm(TeacherContext context)
    {
        Text = "TP Classroom Settings";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterParent;
        ClientSize = new Size(460, 410);
        Font = new Font("Segoe UI", 9.5f);

        var codeLabel = new Label { Text = "Class code (the same on every student computer)", Location = new Point(14, 14), AutoSize = true };
        var code = new TextBox { Text = context.Config.NormalizedClassCode, Location = new Point(14, 36), Width = 300, CharacterCasing = CharacterCasing.Upper };
        var random = new Button { Text = "Random", Location = new Point(322, 35), Width = 120 };
        random.Click += (_, _) => code.Text = SetupForm.RandomCode();

        var nameLabel = new Label { Text = "Your name (students see it)", Location = new Point(14, 72), AutoSize = true };
        var name = new TextBox { Text = context.Config.TeacherDisplayName, Location = new Point(14, 94), Width = 428 };

        var qualityLabel = new Label { Text = "Live view quality", Location = new Point(14, 130), AutoSize = true };
        var quality = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Location = new Point(14, 152), Width = 428 };
        quality.Items.AddRange(new object[] { "Smooth (faster, softer picture)", "Balanced", "Best (sharpest, needs a fast network)" });
        quality.SelectedIndex = context.Config.LiveQuality switch { "smooth" => 0, "balanced" => 1, _ => 2 };

        var startup = new CheckBox { Text = "Start TP Classroom with Windows", Location = new Point(14, 192), AutoSize = true, Checked = AutoStart.IsEnabled };
        var updates = new Label
        {
            Text = $"Version {AppInfo.Version} · {context.Updater.Status}\nStudents get the same version from this PC automatically, even without internet.",
            Location = new Point(14, 222), Size = new Size(428, 44), ForeColor = Color.DimGray,
        };

        bool builtIn = AiAssistant.HasBuiltInKey;
        var aiLabel = new Label
        {
            Text = builtIn ? "TP AI is built in and ready." : "TP AI key (from console.groq.com, only saved on this PC)",
            Location = new Point(14, 274), AutoSize = true,
        };
        var aiKey = new TextBox { Text = context.Config.AiApiKey ?? "", Location = new Point(14, 296), Width = 428, UseSystemPasswordChar = true, Visible = !builtIn };
        var aiNote = new Label { Text = "TP AI needs the internet. Everything else works offline.", Location = new Point(14, builtIn ? 298 : 324), AutoSize = true, ForeColor = Color.DimGray };

        var save = new Button { Text = "Save", DialogResult = DialogResult.OK, Location = new Point(286, 364), Width = 75 };
        var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Location = new Point(367, 364), Width = 75 };
        save.Click += (_, _) =>
        {
            context.Config.TeacherName = name.Text.Trim();
            context.Config.LiveQuality = quality.SelectedIndex switch { 0 => "smooth", 1 => "balanced", _ => "sharp" };
            if (!builtIn) context.Config.AiApiKey = string.IsNullOrWhiteSpace(aiKey.Text) ? null : aiKey.Text.Trim();
            context.Config.Save();
            AutoStart.Set(startup.Checked);
            context.SetClassCode(code.Text);
            foreach (var session in context.Sessions) session.RefreshStream();
        };

        Controls.AddRange(new Control[] { codeLabel, code, random, nameLabel, name, qualityLabel, quality, startup, updates, aiLabel, aiKey, aiNote, save, cancel });
        AcceptButton = save;
        CancelButton = cancel;
    }
}
