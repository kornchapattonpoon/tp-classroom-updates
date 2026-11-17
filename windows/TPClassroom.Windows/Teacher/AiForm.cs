namespace TPClassroom.Teacher;

/// <summary>The TP AI chat window. Closing it only hides it, so the conversation stays.</summary>
sealed class AiForm : Form
{
    readonly AiAssistant assistant;
    readonly RichTextBox transcript = new()
    {
        Dock = DockStyle.Fill, ReadOnly = true, BorderStyle = BorderStyle.None, BackColor = SystemColors.Window,
        Font = new Font("Segoe UI", 10.5f), DetectUrls = true,
    };
    readonly TextBox input = new() { Multiline = true, Height = 54, Dock = DockStyle.Fill, Font = new Font("Segoe UI", 10.5f), AcceptsReturn = false };
    readonly Button send = new() { Text = "Send", Width = 80, Dock = DockStyle.Right };
    readonly Button startOver = new() { Text = "Start Over", AutoSize = true };
    readonly Label working = new() { Text = "Working…", AutoSize = true, ForeColor = Color.DimGray, Visible = false, Padding = new Padding(0, 6, 0, 0) };
    readonly Label setupNote = new()
    {
        Text = "TP AI isn't set up yet: paste an API key in More → Settings → TP AI key.",
        Dock = DockStyle.Bottom, Height = 24, ForeColor = Color.DarkOrange, TextAlign = ContentAlignment.MiddleLeft,
    };

    static readonly string[] Examples =
    {
        "Lock every screen",
        "Open youtube.com on all computers",
        "Shut down all computers",
        "What is on PC-07's screen?",
    };

    public AiForm(AiAssistant assistant)
    {
        this.assistant = assistant;
        Text = "TP AI";
        Icon = Program.LoadIcon("teacher.ico");
        Size = new Size(520, 700);
        MinimumSize = new Size(400, 460);
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Segoe UI", 9.5f);

        var top = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 40, Padding = new Padding(10, 6, 10, 0), FlowDirection = FlowDirection.LeftToRight };
        top.Controls.Add(new Label { Text = "TP AI", Font = new Font("Segoe UI", 13, FontStyle.Bold), AutoSize = true });
        top.Controls.Add(startOver);
        top.Controls.Add(working);
        startOver.Click += (_, _) => assistant.StartOver();

        var examples = new FlowLayoutPanel { Dock = DockStyle.Bottom, AutoSize = true, Padding = new Padding(8, 4, 8, 0) };
        foreach (var example in Examples)
        {
            var link = new LinkLabel { Text = example, AutoSize = true, Margin = new Padding(4, 2, 12, 2) };
            link.LinkClicked += (_, _) => { input.Text = example; input.Focus(); input.SelectionStart = input.Text.Length; };
            examples.Controls.Add(link);
        }

        var bottom = new Panel { Dock = DockStyle.Bottom, Height = 66, Padding = new Padding(10, 6, 10, 6) };
        bottom.Controls.Add(input);
        bottom.Controls.Add(new Panel { Dock = DockStyle.Right, Width = 8 });
        bottom.Controls.Add(send);
        send.Click += (_, _) => Submit();
        input.KeyDown += (_, e) =>
        {
            // Enter sends; Shift+Enter makes a new line.
            if (e.KeyCode == Keys.Enter && !e.Shift)
            {
                e.SuppressKeyPress = true;
                Submit();
            }
            else if (e.KeyCode == Keys.Enter && e.Shift)
            {
                e.SuppressKeyPress = true;
                int at = input.SelectionStart;
                input.Text = input.Text.Insert(at, Environment.NewLine);
                input.SelectionStart = at + Environment.NewLine.Length;
            }
        };

        var transcriptHolder = new Panel { Dock = DockStyle.Fill, Padding = new Padding(12, 6, 12, 6), BackColor = SystemColors.Window };
        transcriptHolder.Controls.Add(transcript);

        Controls.Add(transcriptHolder);
        Controls.Add(examples);
        Controls.Add(setupNote);
        Controls.Add(bottom);
        Controls.Add(top);

        assistant.Owner = this;
        assistant.Changed += Render;
        Render();
    }

    void Submit()
    {
        var text = input.Text.Trim();
        if (text.Length == 0 || assistant.IsWorking) return;
        input.Clear();
        assistant.Send(text);
    }

    void Render()
    {
        if (IsDisposed) return;
        if (InvokeRequired)
        {
            BeginInvoke(new Action(Render));
            return;
        }
        setupNote.Visible = !assistant.IsConfigured;
        working.Visible = assistant.IsWorking;
        send.Enabled = !assistant.IsWorking;
        startOver.Enabled = !assistant.IsWorking && assistant.Lines.Count > 0;

        transcript.SuspendLayout();
        transcript.Clear();
        if (assistant.Lines.Count == 0)
        {
            Append("Ask TP AI to run the class for you. It can lock screens, send messages, open websites, shut down or restart computers, and look at a screen to click and type there.\n", Color.DimGray, FontStyle.Regular);
        }
        foreach (var (kind, text) in assistant.Lines)
        {
            switch (kind)
            {
                case AiKind.Teacher:
                    Append("You\n", Color.SteelBlue, FontStyle.Bold);
                    Append(text + "\n\n", SystemColors.WindowText, FontStyle.Regular);
                    break;
                case AiKind.Assistant:
                    Append("TP AI\n", Color.MediumPurple, FontStyle.Bold);
                    Append(text + "\n\n", SystemColors.WindowText, FontStyle.Regular);
                    break;
                case AiKind.Action:
                    Append("✓ " + text + "\n", Color.DimGray, FontStyle.Italic);
                    break;
                case AiKind.Problem:
                    Append("⚠ " + text + "\n\n", Color.DarkOrange, FontStyle.Bold);
                    break;
            }
        }
        transcript.SelectionStart = transcript.TextLength;
        transcript.ScrollToCaret();
        transcript.ResumeLayout();
    }

    void Append(string text, Color color, FontStyle style)
    {
        transcript.SelectionStart = transcript.TextLength;
        transcript.SelectionLength = 0;
        transcript.SelectionColor = color;
        transcript.SelectionFont = new Font(transcript.Font, style);
        transcript.AppendText(text);
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        input.Focus();
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            Hide();
            return;
        }
        assistant.Changed -= Render;
        base.OnFormClosing(e);
    }
}
