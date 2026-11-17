using System.Diagnostics;
using System.Reflection;
using TPClassroom.Core;
using TPClassroom.Student;
using TPClassroom.Teacher;

namespace TPClassroom;

static class Program
{
    static Mutex? singleInstance;
    static EventWaitHandle? showSignal;

    /// <summary>True once the app really wants to quit (not just hide).</summary>
    public static bool Quitting { get; private set; }

    /// <summary>Another copy was started: show the window.</summary>
    public static event Action? ShowRequested;

    [STAThread]
    static void Main(string[] args)
    {
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        // The installer and uninstaller (see Installer.cs).
        if (args.Length >= 2 && args[0] == "--install")
        {
            Environment.ExitCode = Installer.Install(args[1]);
            return;
        }
        if (args.Contains("--uninstall"))
        {
            Installer.Uninstall();
            return;
        }
        if (!Installer.IsRunningInstalled)
        {
            // Started from the downloaded "TP-Classroom-Setup" file: show the installer.
            Installer.ShowInstaller();
            return;
        }

        WindowsInstaller.CleanupOld();

        bool updated = args.Contains("--updated");
        bool background = args.Contains("--background");

        singleInstance = new Mutex(false, @"Local\TPClassroom");
        if (!AcquireSingleInstance(updated ? 20000 : 0))
        {
            // Already running: ask it to show its window.
            if (EventWaitHandle.TryOpenExisting(@"Local\TPClassroom-Show", out var existing)) existing.Set();
            return;
        }
        showSignal = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\TPClassroom-Show");

        SynchronizationContext.SetSynchronizationContext(new WindowsFormsSynchronizationContext());

        var config = AppConfig.Load();
        if (string.IsNullOrEmpty(config.Role) || string.IsNullOrEmpty(config.NormalizedClassCode))
        {
            using var setup = new SetupForm(config);
            if (setup.ShowDialog() != DialogResult.OK) return;
            config = AppConfig.Load();
            background = false;
        }

        ApplicationContext context = config.IsTeacher
            ? new TeacherContext(config, startHidden: background)
            : new StudentContext(config);

        var signal = showSignal;
        var uiContext = SynchronizationContext.Current!;
        var watcher = new Thread(() =>
        {
            while (signal.WaitOne())
                uiContext.Post(_ => ShowRequested?.Invoke(), null);
        }) { IsBackground = true };
        watcher.Start();

        Application.Run(context);
    }

    static bool AcquireSingleInstance(int waitMilliseconds)
    {
        try
        {
            return singleInstance!.WaitOne(waitMilliseconds);
        }
        catch (AbandonedMutexException)
        {
            return true;   // the previous copy quit without releasing it (e.g. after an update)
        }
    }

    public static Icon LoadIcon(string name)
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(name);
        return stream != null ? new Icon(stream) : SystemIcons.Application;
    }

    /// <summary>Really quit (the menu's "Quit Completely", the admin's "Stop", or an update).</summary>
    public static void QuitCompletely()
    {
        Quitting = true;
        try { singleInstance?.ReleaseMutex(); } catch { /* not owned */ }
        Application.Exit();
        Environment.Exit(0);
    }

    /// <summary>Restart after settings changed.</summary>
    public static void Restart()
    {
        Quitting = true;
        try { singleInstance?.ReleaseMutex(); } catch { /* not owned */ }
        Process.Start(new ProcessStartInfo(AppInfo.ExePath, "--background --updated") { UseShellExecute = false });
        Application.Exit();
        Environment.Exit(0);
    }
}
