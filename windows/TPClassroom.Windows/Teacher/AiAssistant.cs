using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using TPClassroom.Core;

namespace TPClassroom.Teacher;

enum AiKind
{
    Teacher,
    Assistant,
    Action,
    Problem,
}

/// <summary>
/// TP AI: a chat assistant in the teacher app that can run the classroom for the teacher —
/// lock screens, open websites, shut down computers, or look at a screen and click/type there.
/// It talks to an OpenAI-compatible API (Groq by default, set in config.env).
/// </summary>
sealed class AiAssistant
{
    const int MaxSteps = 20;
    readonly TeacherContext context;
    readonly List<JsonNode> history = new();
    readonly Dictionary<string, Size> screenshotSizes = new();

    public AiAssistant(TeacherContext context) => this.context = context;

    public List<(AiKind Kind, string Text)> Lines { get; } = new();
    public bool IsWorking { get; private set; }
    public IWin32Window? Owner { get; set; }
    public event Action? Changed;

    /// <summary>The key built into the app by build.sh (stored scrambled). Like TP Browser, it can't be changed in the app.</summary>
    static readonly string BuiltInKey = Reveal(AppInfo.Metadata("AiKeyX"));
    public static bool HasBuiltInKey => BuiltInKey.Length > 0;
    string ApiKey => HasBuiltInKey ? BuiltInKey : (context.Config.AiApiKey ?? "").Trim();

    static string Reveal(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return "";
        try
        {
            var data = Convert.FromBase64String(text.Trim());
            var mask = Encoding.UTF8.GetBytes("TPClassroom/v1/ai");
            for (int i = 0; i < data.Length; i++) data[i] ^= mask[i % mask.Length];
            return Encoding.UTF8.GetString(data).Trim();
        }
        catch (FormatException)
        {
            return "";
        }
    }
    static string Model => string.IsNullOrWhiteSpace(AppInfo.Metadata("AiModel")) ? "qwen/qwen3.8-27b" : AppInfo.Metadata("AiModel");
    static string BaseUrl => string.IsNullOrWhiteSpace(AppInfo.Metadata("AiBaseUrl")) ? "https://api.groq.com/openai/v1" : AppInfo.Metadata("AiBaseUrl");
    public bool IsConfigured => ApiKey.Length > 0;

    void Add(AiKind kind, string text)
    {
        Lines.Add((kind, text));
        Changed?.Invoke();
    }

    public void StartOver()
    {
        if (IsWorking) return;
        history.Clear();
        Lines.Clear();
        screenshotSizes.Clear();
        Changed?.Invoke();
    }

    public async void Send(string text)
    {
        text = text.Trim();
        if (text.Length == 0 || IsWorking) return;
        if (!IsConfigured)
        {
            Add(AiKind.Problem, "TP AI isn't set up yet. Paste an API key in Settings → TP AI key.");
            return;
        }
        Add(AiKind.Teacher, text);
        history.Add(new JsonObject { ["role"] = "user", ["content"] = text });
        IsWorking = true;
        Changed?.Invoke();
        try
        {
            await RunAsync();
        }
        catch (Exception ex)
        {
            Add(AiKind.Problem, ex.Message);
        }
        finally
        {
            IsWorking = false;
            Changed?.Invoke();
        }
    }

    async Task RunAsync()
    {
        for (int step = 0; step < MaxSteps; step++)
        {
            var message = await CallModelAsync();
            string content = "";
            try { content = (string?)message?["content"] ?? ""; } catch (InvalidOperationException) { /* not text */ }
            var toolCalls = message?["tool_calls"] as JsonArray;

            var assistant = new JsonObject { ["role"] = "assistant", ["content"] = content };
            if (toolCalls != null && toolCalls.Count > 0) assistant["tool_calls"] = toolCalls.DeepClone();
            history.Add(assistant);

            var visible = Clean(content);
            if (visible.Length > 0) Add(AiKind.Assistant, visible);
            if (toolCalls == null || toolCalls.Count == 0) return;

            var images = new List<string>();
            foreach (var call in toolCalls)
            {
                string id = Text(call?["id"]);
                string name = Text(call?["function"]?["name"]);
                string argumentText = Text(call?["function"]?["arguments"], "{}");
                JsonObject arguments;
                try { arguments = JsonNode.Parse(argumentText) as JsonObject ?? new JsonObject(); }
                catch (JsonException) { arguments = new JsonObject(); }

                var (resultText, image) = await RunToolAsync(name, arguments);
                history.Add(new JsonObject { ["role"] = "tool", ["tool_call_id"] = id, ["content"] = resultText });
                if (image != null) images.Add(image);
            }
            if (images.Count > 0)
            {
                var parts = new JsonArray { new JsonObject { ["type"] = "text", ["text"] = "Here is the screenshot you asked for." } };
                foreach (var image in images)
                    parts.Add(new JsonObject { ["type"] = "image_url", ["image_url"] = new JsonObject { ["url"] = image } });
                history.Add(new JsonObject { ["role"] = "user", ["content"] = parts });
                KeepOnlyRecentScreenshots();
            }
        }
        Add(AiKind.Assistant, $"I stopped after {MaxSteps} steps. Tell me if I should keep going.");
    }

    static string Text(JsonNode? node, string fallback = "")
    {
        try { return (string?)node ?? fallback; } catch (InvalidOperationException) { return fallback; }
    }

    /// <summary>The API accepts only a few images per request: replace older screenshots with a note.</summary>
    void KeepOnlyRecentScreenshots(int keep = 1)
    {
        int seen = 0;
        for (int i = history.Count - 1; i >= 0; i--)
        {
            if (history[i]["content"] is not JsonArray parts) continue;
            for (int p = parts.Count - 1; p >= 0; p--)
            {
                if (Text(parts[p]?["type"]) != "image_url") continue;
                seen++;
                if (seen > keep) parts[p] = new JsonObject { ["type"] = "text", ["text"] = "[older screenshot removed]" };
            }
        }
    }

    static string Clean(string text) =>
        Regex.Replace(text, "<think>[\\s\\S]*?</think>", "").Trim();

    /// <summary>Free AI plans only allow a little text per minute: keep just the last few requests.</summary>
    void TrimHistory(int keepTurns = 4)
    {
        var starts = new List<int>();
        for (int i = 0; i < history.Count; i++)
        {
            if (Text(history[i]["role"]) == "user" && history[i]["content"] is JsonValue) starts.Add(i);
        }
        if (starts.Count <= keepTurns) return;
        history.RemoveRange(0, starts[starts.Count - keepTurns]);
    }

    async Task<JsonNode?> CallModelAsync()
    {
        TrimHistory();
        var messages = new JsonArray { new JsonObject { ["role"] = "system", ["content"] = SystemPrompt } };
        foreach (var item in history) messages.Add(item.DeepClone());
        var body = new JsonObject
        {
            ["model"] = Model,
            ["messages"] = messages,
            ["tools"] = Tools(),
            ["tool_choice"] = "auto",
            ["temperature"] = 0.2,
            // Short answers and no hidden "thinking": fits the free plan's per-minute limits and is faster.
            ["max_completion_tokens"] = 500,
            ["reasoning_effort"] = "none",
        };

        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(90) };
        var bodyText = body.ToJsonString();
        for (int attempt = 0; attempt < 5; attempt++)
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, BaseUrl.TrimEnd('/') + "/chat/completions");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", ApiKey);
            request.Content = new StringContent(bodyText, Encoding.UTF8, "application/json");

            HttpResponseMessage response;
            try
            {
                response = await http.SendAsync(request);
            }
            catch (Exception ex)
            {
                throw new InvalidOperationException("TP AI needs the internet. (" + ex.Message + ")");
            }
            using (response)
            {
                int status = (int)response.StatusCode;
                if (status == 429 && attempt < 4)
                {
                    // Too many requests this minute: wait as long as the service asks, then try again.
                    double wait = response.Headers.RetryAfter?.Delta?.TotalSeconds ?? 10;
                    wait = Math.Clamp(wait, 2, 60);
                    Note($"TP AI is busy for a moment. Trying again in {Math.Ceiling(wait)} seconds…");
                    await Task.Delay(TimeSpan.FromSeconds(wait));
                    continue;
                }
                if (status == 413)
                {
                    history.Clear();
                    screenshotSizes.Clear();
                    throw new InvalidOperationException("That was too much for TP AI at once, so I cleared our chat. Please ask again.");
                }
                var text = await response.Content.ReadAsStringAsync();
                JsonNode? json = null;
                try { json = JsonNode.Parse(text); } catch (JsonException) { /* not JSON */ }
                if (!response.IsSuccessStatusCode)
                    throw new InvalidOperationException("TP AI couldn't answer: " + Text(json?["error"]?["message"], "HTTP " + status));
                return json?["choices"]?[0]?["message"] ?? throw new InvalidOperationException("TP AI sent an answer it couldn't read.");
            }
        }
        throw new InvalidOperationException("TP AI is busy right now. Please try again in a minute.");
    }

    // MARK: Instructions and tools

    const string SystemPrompt =
        "You are TP AI, the assistant built into TP Classroom. The teacher uses TP Classroom to watch and help " +
        "the student computers in a classroom (Macs and Windows PCs). Do what the teacher asks by using the tools.\n" +
        "Rules:\n" +
        "- Only act on student computers when the teacher asks you to in this conversation.\n" +
        "- Use computer names from list_computers. Use [\"all\"] for every computer.\n" +
        "- Prefer the direct tools (lock_screens, unlock_screens, send_message, open_website, power) over clicking.\n" +
        "- To click or type on one computer: call look_at_screen first, click using pixel coordinates from that screenshot, then look again to check that it worked.\n" +
        "- Keyboard shortcuts depend on the student computer's system: cmd on a Mac, ctrl on Windows.\n" +
        "- Reply briefly, in the same language the teacher writes in, and say what you did.";

    static JsonObject Tool(string name, string description, JsonObject properties, params string[] required)
    {
        var requiredArray = new JsonArray();
        foreach (var r in required) requiredArray.Add(r);
        return new JsonObject
        {
            ["type"] = "function",
            ["function"] = new JsonObject
            {
                ["name"] = name,
                ["description"] = description,
                ["parameters"] = new JsonObject { ["type"] = "object", ["properties"] = properties, ["required"] = requiredArray },
            },
        };
    }

    static JsonObject Computers() => new()
    {
        ["type"] = "array",
        ["items"] = new JsonObject { ["type"] = "string" },
        ["description"] = "Computer names from list_computers, or [\"all\"] for every computer.",
    };

    static JsonObject Computer() => new() { ["type"] = "string", ["description"] = "One computer name from list_computers." };
    static JsonObject TypeString() => new() { ["type"] = "string" };
    static JsonObject OneOf(params string[] values)
    {
        var list = new JsonArray();
        foreach (var v in values) list.Add(v);
        return new JsonObject { ["type"] = "string", ["enum"] = list };
    }

    static JsonArray Tools() => new()
    {
        Tool("list_computers", "List the student computers with their system, whether they're online and locked.", new JsonObject()),
        Tool("lock_screens", "Lock student screens with a message.",
             new JsonObject { ["computers"] = Computers(), ["message"] = TypeString() }, "computers"),
        Tool("unlock_screens", "Unlock student screens.", new JsonObject { ["computers"] = Computers() }, "computers"),
        Tool("send_message", "Show a message on student screens.",
             new JsonObject { ["computers"] = Computers(), ["text"] = TypeString() }, "computers", "text"),
        Tool("open_website", "Open a website on student computers.",
             new JsonObject { ["computers"] = Computers(), ["url"] = TypeString() }, "computers", "url"),
        Tool("power", "Shut down or restart student computers. The teacher is asked to confirm first; students get a 15-second warning.",
             new JsonObject { ["computers"] = Computers(), ["action"] = OneOf("shutdown", "restart") }, "computers", "action"),
        Tool("look_at_screen", "Get a current screenshot of one student computer.", new JsonObject { ["computer"] = Computer() }, "computer"),
        Tool("click", "Click on one student computer at pixel coordinates from its latest screenshot.",
             new JsonObject
             {
                 ["computer"] = Computer(), ["x"] = new JsonObject { ["type"] = "number" }, ["y"] = new JsonObject { ["type"] = "number" },
                 ["button"] = OneOf("left", "right"), ["double"] = new JsonObject { ["type"] = "boolean" },
             }, "computer", "x", "y"),
        Tool("type_text", "Type text on one student computer, into whatever is selected there.",
             new JsonObject { ["computer"] = Computer(), ["text"] = TypeString() }, "computer", "text"),
        Tool("press_keys", "Press a key or shortcut on one student computer, e.g. \"enter\", \"cmd+s\", \"ctrl+alt+t\", \"tab\".",
             new JsonObject { ["computer"] = Computer(), ["keys"] = TypeString() }, "computer", "keys"),
    };

    // MARK: Running tools

    void Note(string text) => Add(AiKind.Action, text);

    List<TeacherSession> Resolve(JsonNode? value)
    {
        var names = new List<string>();
        if (value is JsonArray array)
        {
            foreach (var item in array)
            {
                var name = Text(item);
                if (name.Length > 0) names.Add(name);
            }
        }
        else if (Text(value) is { Length: > 0 } single)
        {
            names.Add(single);
        }
        if (names.Count == 0 || names.Any(n => n.Equals("all", StringComparison.OrdinalIgnoreCase)))
            return context.Sessions.ToList();
        return context.Sessions
            .Where(s => names.Any(n => n.Equals(s.Name, StringComparison.OrdinalIgnoreCase) || n == s.Id))
            .ToList();
    }

    TeacherSession? ResolveOne(JsonNode? value)
    {
        var name = Text(value);
        return context.Sessions.FirstOrDefault(s => s.Name.Equals(name, StringComparison.OrdinalIgnoreCase) || s.Id == name);
    }

    static double Number(JsonNode? node)
    {
        try { return node?.GetValue<double>() ?? 0; }
        catch
        {
            return double.TryParse(Text(node), NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed) ? parsed : 0;
        }
    }

    static bool Flag(JsonNode? node)
    {
        try { return node?.GetValue<bool>() ?? false; } catch { return false; }
    }

    static string Names(IEnumerable<TeacherSession> sessions) => string.Join(", ", sessions.Select(s => s.Name));

    async Task<(string Text, string? Image)> RunToolAsync(string name, JsonObject args)
    {
        switch (name)
        {
            case "list_computers":
            {
                var list = new JsonArray();
                foreach (var s in context.Sessions)
                    list.Add(new JsonObject
                    {
                        ["name"] = s.Name, ["system"] = s.IsWindows ? "windows" : "mac",
                        ["online"] = s.IsOnline, ["locked"] = s.IsLocked, ["user"] = s.User,
                    });
                return (new JsonObject { ["computers"] = list }.ToJsonString(), null);
            }
            case "lock_screens":
            {
                var targets = Resolve(args["computers"]);
                var message = Text(args["message"]);
                if (message.Length == 0) message = "Eyes on the teacher, please";
                foreach (var s in targets) s.Lock(message);
                Note($"Locked {targets.Count} screen(s)");
                return ($"Locked: {Names(targets)}. Offline computers lock when they come back.", null);
            }
            case "unlock_screens":
            {
                var targets = Resolve(args["computers"]);
                foreach (var s in targets) s.Unlock();
                Note($"Unlocked {targets.Count} screen(s)");
                return ($"Unlocked: {Names(targets)}.", null);
            }
            case "send_message":
            {
                var targets = Resolve(args["computers"]).Where(s => s.IsOnline).ToList();
                var text = Text(args["text"]);
                foreach (var s in targets) s.Send(new NetMessage { Type = "message", Text = text });
                Note($"Sent a message to {targets.Count} computer(s)");
                return ($"Message shown on: {Names(targets)}.", null);
            }
            case "open_website":
            {
                var url = TeacherContext.NormalizeUrl(Text(args["url"]));
                if (url == null) return ("That isn't a web address.", null);
                var targets = Resolve(args["computers"]).Where(s => s.IsOnline).ToList();
                foreach (var s in targets) s.Send(new NetMessage { Type = "openUrl", Url = url });
                Note($"Opened {url} on {targets.Count} computer(s)");
                return ($"Opened {url} on: {Names(targets)}.", null);
            }
            case "power":
            {
                bool restart = Text(args["action"]) == "restart";
                var targets = Resolve(args["computers"]).Where(s => s.IsOnline).ToList();
                if (targets.Count == 0) return ("None of those computers are online.", null);
                var question = $"TP AI wants to {(restart ? "restart" : "shut down")}: {Names(targets)}.\n\nStudents get a 15-second warning to save their work.";
                var answer = MessageBox.Show(Owner, question,
                                             restart ? $"Restart {targets.Count} computer(s)?" : $"Shut down {targets.Count} computer(s)?",
                                             MessageBoxButtons.OKCancel, MessageBoxIcon.Warning);
                if (answer != DialogResult.OK)
                {
                    Note("You cancelled");
                    return ("The teacher cancelled. Nothing was changed.", null);
                }
                foreach (var s in targets) s.Power(restart ? "restart" : "shutdown");
                Note($"{(restart ? "Restarting" : "Shutting down")} {targets.Count} computer(s)");
                return ($"{(restart ? "Restarting" : "Shutting down")}: {Names(targets)}.", null);
            }
            case "look_at_screen":
            {
                var s = ResolveOne(args["computer"]);
                if (s == null) return ("I can't find that computer.", null);
                if (!s.IsOnline) return ($"{s.Name} is offline.", null);
                Note($"Looking at {s.Name}");
                var before = s.Frame;
                s.OpenLiveView();   // a bigger, fresher picture
                for (int i = 0; i < 30; i++)
                {
                    var current = s.Frame;
                    if (current != null && current != before && current.Width > 480) break;
                    await Task.Delay(100);
                }
                s.CloseLiveView();
                var frame = s.Frame;
                if (frame == null) return ($"No picture from {s.Name} yet.", null);
                var (dataUrl, size) = ToJpegDataUrl(frame);
                screenshotSizes[s.Id] = size;
                return ($"Screenshot of {s.Name} ({(s.IsWindows ? "Windows" : "Mac")}), {size.Width}×{size.Height} pixels. Use these pixel coordinates for click.", dataUrl);
            }
            case "click":
            {
                var s = ResolveOne(args["computer"]);
                if (s == null || !s.IsOnline) return ("That computer isn't online.", null);
                if (!screenshotSizes.TryGetValue(s.Id, out var size) || size.Width == 0 || size.Height == 0)
                    return ($"Call look_at_screen for {s.Name} first.", null);
                double x = Math.Clamp(Number(args["x"]) / size.Width, 0, 1);
                double y = Math.Clamp(Number(args["y"]) / size.Height, 0, 1);
                int button = Text(args["button"]) == "right" ? 1 : 0;
                var events = new List<InputEvent>
                {
                    InputEvent.Move(x, y),
                    InputEvent.Press(button, true, x, y, 1),
                    InputEvent.Press(button, false, x, y, 1),
                };
                if (Flag(args["double"]))
                {
                    events.Add(InputEvent.Press(button, true, x, y, 2));
                    events.Add(InputEvent.Press(button, false, x, y, 2));
                }
                await s.PerformAiInputAsync(events);
                Note($"Clicked on {s.Name}");
                await Task.Delay(700);
                return ("Clicked. Look at the screen again to check.", null);
            }
            case "type_text":
            {
                var s = ResolveOne(args["computer"]);
                if (s == null || !s.IsOnline) return ("That computer isn't online.", null);
                var text = Text(args["text"]);
                await s.TypeTextAsAiAsync(text);
                Note($"Typed on {s.Name}");
                await Task.Delay(300 + text.Length * 10);
                return ($"Typed {text.Length} characters.", null);
            }
            case "press_keys":
            {
                var s = ResolveOne(args["computer"]);
                if (s == null || !s.IsOnline) return ("That computer isn't online.", null);
                var keys = Text(args["keys"]);
                var codes = ParseKeys(keys);
                if (codes == null) return ("I don't know those keys. Use names like enter, tab, esc, cmd+s, ctrl+c.", null);
                await s.PerformAiInputAsync(KeyEvents(codes, studentIsWindows: s.IsWindows));
                Note($"Pressed {keys} on {s.Name}");
                await Task.Delay(500);
                return ("Pressed.", null);
            }
            default:
                return ($"Unknown tool {name}.", null);
        }
    }

    // MARK: Keys

    static readonly Dictionary<char, string> SymbolCodes = new()
    {
        ['-'] = "Minus", ['='] = "Equal", [','] = "Comma", ['.'] = "Period", ['/'] = "Slash", [';'] = "Semicolon",
        ['\''] = "Quote", ['['] = "BracketLeft", [']'] = "BracketRight", ['\\'] = "Backslash", ['`'] = "Backquote",
    };

    /// <summary>"ctrl+shift+s" → ControlLeft, ShiftLeft, KeyS</summary>
    static List<string>? ParseKeys(string text)
    {
        var codes = new List<string>();
        foreach (var raw in text.ToLowerInvariant().Split('+', StringSplitOptions.RemoveEmptyEntries))
        {
            var part = raw.Trim();
            string? code = part switch
            {
                "cmd" or "command" or "meta" or "win" or "windows" or "super" => "MetaLeft",
                "ctrl" or "control" => "ControlLeft",
                "alt" or "option" or "opt" => "AltLeft",
                "shift" => "ShiftLeft",
                "enter" or "return" => "Enter",
                "esc" or "escape" => "Escape",
                "tab" => "Tab",
                "space" => "Space",
                "backspace" => "Backspace",
                "delete" or "del" => "Delete",
                "up" => "ArrowUp",
                "down" => "ArrowDown",
                "left" => "ArrowLeft",
                "right" => "ArrowRight",
                "home" => "Home",
                "end" => "End",
                "pageup" => "PageUp",
                "pagedown" => "PageDown",
                _ => null,
            };
            if (code == null && part.Length == 1)
            {
                char c = part[0];
                if (c >= 'a' && c <= 'z') code = "Key" + char.ToUpperInvariant(c);
                else if (c >= '0' && c <= '9') code = "Digit" + c;
                else if (SymbolCodes.TryGetValue(c, out var symbol)) code = symbol;
            }
            else if (code == null && part.StartsWith('f') && int.TryParse(part[1..], out var number) && number >= 1 && number <= 12)
            {
                code = "F" + number;
            }
            if (code == null) return null;
            codes.Add(code);
        }
        return codes.Count == 0 ? null : codes;
    }

    /// <summary>
    /// Presses keys in order, releases in reverse. This teacher app runs on Windows, so for a Mac student
    /// the keys are pre-swapped (the student swaps ⌘/Ctrl back), keeping them literal.
    /// </summary>
    static List<InputEvent> KeyEvents(List<string> codes, bool studentIsWindows)
    {
        var sent = studentIsWindows ? codes : codes.Select(c => KeyMap.SwapMetaAndControl(c)).ToList();
        int mods = 0;
        var events = new List<InputEvent>();
        foreach (var code in sent)
        {
            mods |= code switch
            {
                "ShiftLeft" => Mods.Shift,
                "ControlLeft" => Mods.Control,
                "AltLeft" => Mods.Alt,
                "MetaLeft" => Mods.Meta,
                _ => 0,
            };
            events.Add(InputEvent.Key(code, true, mods));
        }
        for (int i = sent.Count - 1; i >= 0; i--) events.Add(InputEvent.Key(sent[i], false, mods));
        return events;
    }

    // MARK: Screenshots

    static readonly ImageCodecInfo JpegCodec = ImageCodecInfo.GetImageEncoders().First(c => c.FormatID == ImageFormat.Jpeg.Guid);

    static (string DataUrl, Size Size) ToJpegDataUrl(Image frame, int maxWidth = 1280)
    {
        int width = Math.Min(maxWidth, frame.Width);
        int height = Math.Max(1, (int)((long)frame.Height * width / Math.Max(1, frame.Width)));
        using var bitmap = new Bitmap(width, height, PixelFormat.Format24bppRgb);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.InterpolationMode = InterpolationMode.HighQualityBilinear;
            g.DrawImage(frame, 0, 0, width, height);
        }
        using var output = new MemoryStream();
        using var parameters = new EncoderParameters(1);
        parameters.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, 60L);
        bitmap.Save(output, JpegCodec, parameters);
        return ("data:image/jpeg;base64," + Convert.ToBase64String(output.ToArray()), new Size(width, height));
    }
}
