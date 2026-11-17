using System.Security.Cryptography;
using TPClassroom.Core;

namespace TPClassroom;

/// <summary>Student settings (name) and a fallback first-run setup: teacher or student?</summary>
sealed class SetupForm : Form
{
    public SetupForm(AppConfig config, bool studentOnly = false)
    {
        Text = "Set up TP Classroom";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(480, 380);
        Font = new Font("Segoe UI", 9.5f);
        Icon = Program.LoadIcon(config.IsTeacher ? "teacher.ico" : "student.ico");

        var title = new Label { Text = "Set up TP Classroom", Font = new Font("Segoe UI", 15, FontStyle.Bold), Location = new Point(16, 12), AutoSize = true };
        var teacher = new RadioButton { Text = "This is the teacher's computer", Location = new Point(18, 56), AutoSize = true, Checked = config.IsTeacher };
        var student = new RadioButton { Text = "This is a student computer", Location = new Point(18, 82), AutoSize = true, Checked = !config.IsTeacher };
        if (studentOnly || config.Managed)
        {
            teacher.Enabled = false;
            student.Enabled = false;
        }

        var codeLabel = new Label { Text = "Class code (the same on the teacher's and every student's computer)", Location = new Point(16, 118), AutoSize = true };
        var code = new TextBox { Text = config.NormalizedClassCode, Location = new Point(18, 140), Width = 300, CharacterCasing = CharacterCasing.Upper, Enabled = !config.Managed };
        var random = new Button { Text = "Random", Location = new Point(326, 139), Width = 136, Enabled = !config.Managed };
        random.Click += (_, _) => code.Text = RandomCode();

        var nameLabel = new Label { Location = new Point(16, 176), AutoSize = true };
        var name = new TextBox { Location = new Point(18, 198), Width = 444 };

        var pinLabel = new Label { Text = "Admin PIN (protects Stop and Settings on student computers)", Location = new Point(16, 234), AutoSize = true };
        var pin = new TextBox { Location = new Point(18, 256), Width = 444, UseSystemPasswordChar = true, Enabled = !config.Managed };

        var note = new Label
        {
            Location = new Point(16, 290), Size = new Size(448, 36), ForeColor = Color.DimGray,
            Text = "Students always see an icon in the notification area and a banner while the teacher is watching or helping.",
        };
        var save = new Button { Text = "Save", Location = new Point(306, 336), Width = 75 };
        var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Location = new Point(387, 336), Width = 75 };

        void UpdateRole()
        {
            bool isTeacher = teacher.Checked;
            nameLabel.Text = isTeacher ? "Your name (students see it)" : "Name shown to the teacher";
            name.Text = isTeacher ? config.TeacherDisplayName : config.StudentName;
            pinLabel.Visible = !isTeacher;
            pin.Visible = !isTeacher;
        }
        teacher.CheckedChanged += (_, _) => UpdateRole();
        UpdateRole();

        save.Click += (_, _) =>
        {
            var normalized = ClassCrypto.Normalize(code.Text);
            if (normalized.Length == 0)
            {
                MessageBox.Show(this, "Type a class code.", "TP Classroom");
                return;
            }
            config.Role = teacher.Checked ? "teacher" : "student";
            if (!config.Managed)
            {
                config.ClassCode = normalized;
                if (!teacher.Checked && pin.Text.Length > 0) config.AdminPinHash = AppConfig.HashPin(pin.Text);
            }
            if (teacher.Checked) config.TeacherName = name.Text.Trim();
            else config.DisplayName = name.Text.Trim();
            config.Save();
            if (!config.Managed) AutoStart.Set(true);
            DialogResult = DialogResult.OK;
            Close();
        };

        Controls.AddRange(new Control[] { title, teacher, student, codeLabel, code, random, nameLabel, name, pinLabel, pin, note, save, cancel });
        AcceptButton = save;
        CancelButton = cancel;
    }

    public static string RandomCode()
    {
        const string alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
        var chars = new char[8];
        for (int i = 0; i < chars.Length; i++) chars[i] = alphabet[RandomNumberGenerator.GetInt32(alphabet.Length)];
        return new string(chars);
    }
}
