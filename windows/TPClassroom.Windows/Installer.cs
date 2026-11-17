using System.ComponentModel;
using System.Diagnostics;
using System.Security.Principal;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Win32;
using TPClassroom.Core;

namespace TPClassroom;

/// <summary>What the installer window asked for, handed to the elevated (administrator) part.</summary>
sealed class InstallRequest
{
    public string Role { get; set; } = "student";
    public string ClassCode { get; set; } = "";
    public string? AdminPinHash { get; set; }
    public string? Name { get; set; }
}

/// <summary>
/// "TP-Classroom-Setup-x.y.z.exe" is the app itself. Run from anywhere except Program Files, it shows the
/// installer: it copies itself to C:\Program Files\TP Classroom, starts for every user at sign-in,
/// allows itself through Windows Firewall and appears in Settings → Apps for uninstalling.
/// </summary>
static class Installer
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\TPClassroom";

    public static string InstallDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "TP Classroom");

    public static string InstalledExe => Path.Combine(InstallDir, "TPClassroom.exe");

    public static bool IsRunningInstalled =>
        string.Equals(Path.GetFullPath(AppInfo.ExePath), Path.GetFullPath(InstalledExe), StringComparison.OrdinalIgnoreCase);

    static bool IsAdministrator =>
        new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator);

    public static void ShowInstaller()
    {
        using var form = new InstallForm();
        form.ShowDialog();
    }

    /// <summary>Runs this program again as administrator (Windows asks "Allow this app…?") to do the install.</summary>
    public static bool RunElevated(InstallRequest request, IWin32Window owner)
    {
        var requestFile = Path.Combine(Path.GetTempPath(), $"tpclassroom-install-{Guid.NewGuid():N}.json");
        File.WriteAllText(requestFile, JsonSerializer.Serialize(request, Json.Options));
        try
        {
            var start = new ProcessStartInfo(AppInfo.ExePath, $"--install \"{requestFile}\"")
            {
                UseShellExecute = true,
                Verb = "runas",
            };
            using var process = Process.Start(start);
            if (process == null) return false;
            process.WaitForExit();
            return process.ExitCode == 0;
        }
        catch (Win32Exception)
        {
            MessageBox.Show(owner, "Installing needs administrator permission. Please click Yes when Windows asks.",
                            "TP Classroom", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return false;
        }
        finally
        {
            try { File.Delete(requestFile); } catch { /* ignore */ }
        }
    }

    /// <summary>The administrator part of the install. Returns the process exit code.</summary>
    public static int Install(string requestFile)
    {
        try
        {
            if (!IsAdministrator) throw new InvalidOperationException("Administrator permission is needed.");
            var request = JsonSerializer.Deserialize<InstallRequest>(File.ReadAllText(requestFile), Json.Options)
                          ?? throw new InvalidOperationException("The install settings are missing.");

            StopRunningCopies();

            Directory.CreateDirectory(InstallDir);
            // Every user (group "Users") may replace the app, so updates work with standard accounts.
            Run("icacls", $"\"{InstallDir}\" /grant *S-1-5-32-545:(OI)(CI)M /T /Q");
            try { File.Delete(InstalledExe + ".old"); } catch { /* ignore */ }
            File.Copy(AppInfo.ExePath, InstalledExe, overwrite: true);

            // Settings for every user on this PC.
            Directory.CreateDirectory(AppInfo.MachineDataDir);
            var config = new AppConfig
            {
                Role = request.Role,
                ClassCode = ClassCrypto.Normalize(request.ClassCode),
                AdminPinHash = request.Role == "student" ? request.AdminPinHash : null,
                TeacherName = request.Role == "teacher" ? request.Name : null,
                DisplayName = request.Role == "student" ? request.Name : null,
            };
            File.WriteAllText(Path.Combine(AppInfo.MachineDataDir, "config.json"), JsonSerializer.Serialize(config, Json.Options));

            // Start for every user at sign-in.
            using (var run = Registry.LocalMachine.CreateSubKey(RunKey))
            {
                run.SetValue("TP Classroom", $"\"{InstalledExe}\" --background");
            }

            // Windows Firewall: let teachers and students reach each other.
            Run("netsh", "advfirewall firewall delete rule name=\"TP Classroom\"");
            Run("netsh", $"advfirewall firewall add rule name=\"TP Classroom\" dir=in action=allow program=\"{InstalledExe}\" enable=yes profile=any");

            // Settings → Apps → TP Classroom → Uninstall
            using (var key = Registry.LocalMachine.CreateSubKey(UninstallKey))
            {
                key.SetValue("DisplayName", "TP Classroom");
                key.SetValue("DisplayVersion", AppInfo.Version);
                key.SetValue("Publisher", "TP Classroom");
                key.SetValue("DisplayIcon", InstalledExe);
                key.SetValue("InstallLocation", InstallDir);
                key.SetValue("UninstallString", $"\"{InstalledExe}\" --uninstall");
                key.SetValue("NoModify", 1, RegistryValueKind.DWord);
                key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
                key.SetValue("EstimatedSize", (int)(new FileInfo(InstalledExe).Length / 1024), RegistryValueKind.DWord);
            }

            // Start it now as the signed-in user (not as administrator).
            Process.Start(new ProcessStartInfo("explorer.exe", $"\"{InstalledExe}\"") { UseShellExecute = false });
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show("Installation failed: " + ex.Message, "TP Classroom", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    /// <summary>Settings → Apps → Uninstall runs "TPClassroom.exe --uninstall".</summary>
    public static void Uninstall()
    {
        if (!IsAdministrator)
        {
            try
            {
                Process.Start(new ProcessStartInfo(AppInfo.ExePath, "--uninstall") { UseShellExecute = true, Verb = "runas" });
            }
            catch (Win32Exception)
            {
                // The user said no.
            }
            return;
        }
        if (MessageBox.Show("Remove TP Classroom from this PC?", "TP Classroom",
                            MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;

        StopRunningCopies();
        using (var run = Registry.LocalMachine.OpenSubKey(RunKey, true)) run?.DeleteValue("TP Classroom", false);
        using (var run = Registry.CurrentUser.OpenSubKey(RunKey, true)) run?.DeleteValue("TP Classroom", false);
        Run("netsh", "advfirewall firewall delete rule name=\"TP Classroom\"");
        Registry.LocalMachine.DeleteSubKeyTree(UninstallKey, false);
        try { Directory.Delete(AppInfo.MachineDataDir, true); } catch { /* ignore */ }

        MessageBox.Show("TP Classroom was removed.", "TP Classroom", MessageBoxButtons.OK, MessageBoxIcon.Information);
        // This program is inside the folder, so the folder is deleted a moment after it quits.
        Process.Start(new ProcessStartInfo("cmd.exe", $"/c ping 127.0.0.1 -n 3 > nul & rmdir /s /q \"{InstallDir}\"")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
        });
    }

    static void StopRunningCopies()
    {
        foreach (var process in Process.GetProcessesByName("TPClassroom"))
        {
            using (process)
            {
                if (process.Id == Environment.ProcessId) continue;
                try
                {
                    process.Kill();
                    process.WaitForExit(5000);
                }
                catch
                {
                    // Already gone.
                }
            }
        }
    }

    static void Run(string file, string arguments)
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo(file, arguments) { UseShellExecute = false, CreateNoWindow = true });
            process?.WaitForExit(30000);
        }
        catch
        {
            // Not fatal for the install.
        }
    }
}

/// <summary>The installer window.</summary>
sealed class InstallForm : Form
{
    public InstallForm()
    {
        var existing = AppConfig.Load();   // pre-filled when updating or re-installing
        Text = "Install TP Classroom " + AppInfo.Version;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(500, 420);
        Font = new Font("Segoe UI", 9.5f);
        Icon = Program.LoadIcon("teacher.ico");

        var title = new Label { Text = "Install TP Classroom", Font = new Font("Segoe UI", 16, FontStyle.Bold), Location = new Point(16, 12), AutoSize = true };
        var subtitle = new Label
        {
            Text = $"Version {AppInfo.Version}. Installs for every user on this PC and starts automatically.",
            Location = new Point(18, 48), AutoSize = true, ForeColor = Color.DimGray,
        };
        var teacher = new RadioButton { Text = "This is the teacher's computer", Location = new Point(20, 82), AutoSize = true, Checked = existing.IsTeacher };
        var student = new RadioButton { Text = "This is a student computer", Location = new Point(20, 108), AutoSize = true, Checked = !existing.IsTeacher };

        var codeLabel = new Label { Text = "Class code (the same on the teacher's and every student's computer)", Location = new Point(18, 144), AutoSize = true };
        var code = new TextBox { Text = existing.NormalizedClassCode, Location = new Point(20, 166), Width = 320, CharacterCasing = CharacterCasing.Upper };
        var random = new Button { Text = "Random", Location = new Point(348, 165), Width = 132 };
        random.Click += (_, _) => code.Text = SetupForm.RandomCode();

        var nameLabel = new Label { Location = new Point(18, 202), AutoSize = true };
        var name = new TextBox { Location = new Point(20, 224), Width = 460 };

        var pinLabel = new Label { Text = "Admin PIN (needed to stop TP Classroom or change its settings)", Location = new Point(18, 260), AutoSize = true };
        var pin = new TextBox { Location = new Point(20, 282), Width = 460, UseSystemPasswordChar = true };

        var note = new Label
        {
            Location = new Point(18, 316), Size = new Size(462, 40), ForeColor = Color.DimGray,
            Text = "Students always see the TP Classroom icon, and a banner while the teacher is watching or helping.",
        };
        var install = new Button { Text = "Install", Location = new Point(324, 372), Width = 75 };
        var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Location = new Point(405, 372), Width = 75 };

        void UpdateRole()
        {
            bool isTeacher = teacher.Checked;
            nameLabel.Text = isTeacher ? "Your name (students see it)" : "Name shown to the teacher";
            name.Text = isTeacher ? existing.TeacherDisplayName : existing.StudentName;
            pinLabel.Visible = !isTeacher;
            pin.Visible = !isTeacher;
        }
        teacher.CheckedChanged += (_, _) => UpdateRole();
        UpdateRole();

        install.Click += (_, _) =>
        {
            var normalized = ClassCrypto.Normalize(code.Text);
            if (!Regex.IsMatch(normalized, "^[A-Z0-9_-]+$"))
            {
                MessageBox.Show(this, "Type a class code using letters, numbers, - or _.", "TP Classroom");
                return;
            }
            var request = new InstallRequest
            {
                Role = teacher.Checked ? "teacher" : "student",
                ClassCode = normalized,
                Name = name.Text.Trim(),
                AdminPinHash = pin.Text.Length > 0 ? AppConfig.HashPin(pin.Text) : existing.AdminPinHash,
            };
            install.Enabled = false;
            install.Text = "Installing…";
            if (Installer.RunElevated(request, this))
            {
                MessageBox.Show(this,
                    teacher.Checked
                        ? "TP Classroom is installed. Student computers on this network with the same class code appear by themselves."
                        : "TP Classroom is installed. Look for its icon in the notification area, next to the clock.",
                    "TP Classroom", MessageBoxButtons.OK, MessageBoxIcon.Information);
                DialogResult = DialogResult.OK;
                Close();
            }
            else
            {
                install.Enabled = true;
                install.Text = "Install";
            }
        };

        Controls.AddRange(new Control[] { title, subtitle, teacher, student, codeLabel, code, random, nameLabel, name, pinLabel, pin, note, install, cancel });
        AcceptButton = install;
        CancelButton = cancel;
    }
}
