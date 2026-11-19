// cooked.exe: native helper for the /cooked notification hooks. Built by cooked.ps1 install.
//   cooked.exe "cooked:?hwnd=..&tab=..[&dry=1]"   click handler: jump to the session's terminal tab
//   cooked.exe --mark                             UserPromptSubmit: stamp the prompt start time (prints nothing)
//   cooked.exe --play <file>                      play the notification sound, no window
// notify.ps1 also loads this file as an assembly and calls the public helpers.
// State and the last click log live in .state\ next to this file.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Automation;

public static class Cooked
{
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern void SwitchToThisWindow(IntPtr h, bool altTab);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr p, IntPtr after, string cls, string title);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO lii);
    [DllImport("shell32.dll")] static extern int SHQueryUserNotificationState(out int state);
    [DllImport("ntdll.dll")] static extern int NtQueryWnfStateData(ref ulong name, IntPtr type, IntPtr scope, out uint stamp, byte[] buf, ref uint size);
    [DllImport("winmm.dll", CharSet = CharSet.Unicode)] static extern int mciSendString(string cmd, StringBuilder ret, int len, IntPtr cb);
    [DllImport("kernel32.dll")] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32FirstW(IntPtr snap, ref PROCESSENTRY32 pe);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32NextW(IntPtr snap, ref PROCESSENTRY32 pe);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct PROCESSENTRY32
    {
        public uint dwSize, cntUsage, th32ProcessID; public IntPtr th32DefaultHeapID;
        public uint th32ModuleID, cntThreads, th32ParentProcessID; public int pcPriClassBase; public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }

    const string WT_CLASS = "CASCADIA_HOSTING_WINDOW_CLASS";
    // Windows' Focus / Do Not Disturb profile (undocumented WNF state; 0 = off).
    const ulong WNF_QUIET_HOURS = 0x0D83063EA3BF1C75UL;

    public static string StateDir
    {
        get
        {
            string d = Path.Combine(Path.GetDirectoryName(typeof(Cooked).Assembly.Location), ".state");
            Directory.CreateDirectory(d);
            return d;
        }
    }

    [STAThread]
    public static void Main(string[] args)
    {
        string a0 = args.Length > 0 ? args[0] : "";
        bool click = a0 != "--mark" && a0 != "--play";
        try
        {
            if (a0 == "--mark") Mark();
            else if (a0 == "--play") { if (args.Length > 1) Play(args[1]); }
            else Focus(a0);
        }
        catch (Exception e) { if (click) log += "error: " + e.Message + "\n"; }
        if (click)
        {
            try { File.WriteAllText(Path.Combine(StateDir, "click.log"), DateTime.Now.ToString("s") + "\n" + log); } catch { }
        }
    }

    // UserPromptSubmit: remember when this prompt started. Must print nothing: stdout would reach the model.
    static void Mark()
    {
        Match m = Regex.Match(Console.In.ReadToEnd(), "\"session_id\"\\s*:\\s*\"([A-Za-z0-9-]+)\"");
        if (!m.Success) return;
        File.WriteAllText(Path.Combine(StateDir, m.Groups[1].Value + ".start"),
            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString());
    }

    // MCI plays mp3/wav/wma synchronously; this process exists only for the length of the sound.
    static void Play(string file)
    {
        if (!File.Exists(file)) return;
        mciSendString("open \"" + file + "\" type mpegvideo alias cookedsnd", null, 0, IntPtr.Zero);
        mciSendString("play cookedsnd wait", null, 0, IntPtr.Zero);
        mciSendString("close cookedsnd", null, 0, IntPtr.Zero);
    }

    // ---------- helpers for notify.ps1 ----------

    // First process up the tree that owns a visible main window (Windows Terminal, VS Code, a console host).
    public static long TerminalWindow(int pid)
    {
        var parent = new Dictionary<uint, uint>();
        IntPtr snap = CreateToolhelp32Snapshot(2, 0);
        var pe = new PROCESSENTRY32 { dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32)) };
        if (Process32FirstW(snap, ref pe)) do { parent[pe.th32ProcessID] = pe.th32ParentProcessID; } while (Process32NextW(snap, ref pe));
        CloseHandle(snap);
        uint p = (uint)pid;
        for (int i = 0; i < 12 && p != 0; i++)
        {
            try { IntPtr h = Process.GetProcessById((int)p).MainWindowHandle; if (h != IntPtr.Zero) return h.ToInt64(); } catch { }
            uint pp;
            if (!parent.TryGetValue(p, out pp) || pp == p) break;
            p = pp;
        }
        return 0;
    }

    public static int IdleSeconds()
    {
        var l = new LASTINPUTINFO { cbSize = 8 };
        if (!GetLastInputInfo(ref l)) return 0;
        return (int)(unchecked((uint)Environment.TickCount - l.dwTime) / 1000);
    }

    // True when Windows should stay silent: fullscreen app or game, presentation mode, Do Not Disturb / Focus.
    public static bool Quiet() { int q, f; Read(out q, out f); return q == 2 || q == 3 || q == 4 || q == 7 || f > 0; }
    public static string QuietDetail() { int q, f; Read(out q, out f); return "quns=" + q + " focus=" + f; }

    static void Read(out int quns, out int focus)
    {
        quns = -1; focus = -1;
        try { int s; if (SHQueryUserNotificationState(out s) == 0) quns = s; } catch { }
        try
        {
            ulong name = WNF_QUIET_HOURS; uint stamp; var buf = new byte[4]; uint size = 4;
            if (NtQueryWnfStateData(ref name, IntPtr.Zero, IntPtr.Zero, out stamp, buf, ref size) == 0 && size >= 4)
                focus = BitConverter.ToInt32(buf, 0);
        }
        catch { }
    }

    // Is the user looking at this session right now? The foreground window must be the session's
    // terminal; in Windows Terminal its tab must also be the selected one.
    public static bool Watching(long hwnd, string session)
    {
        IntPtr fg = GetForegroundWindow();
        if (fg == IntPtr.Zero) return false;
        var cls = new StringBuilder(256); GetClassName(fg, cls, 256);
        if (cls.ToString() == WT_CLASS)
        {
            if (string.IsNullOrEmpty(session)) return false;
            AutomationElement t = FindTab(fg, Norm(session));
            object p;
            return t != null && t.TryGetCurrentPattern(SelectionItemPattern.Pattern, out p)
                && ((SelectionItemPattern)p).Current.IsSelected;
        }
        return fg.ToInt64() == hwnd;
    }

    // ---------- click handler ----------
    static string log = "";

    static void Focus(string uri)
    {
        long hv = 0; string tab = null; bool dry = false;
        int q = uri.IndexOf('?');
        if (q >= 0)
        {
            foreach (string kv in uri.Substring(q + 1).Split('&'))
            {
                int e = kv.IndexOf('=');
                if (e < 0) continue;
                string k = kv.Substring(0, e), v = Uri.UnescapeDataString(kv.Substring(e + 1));
                if (k == "hwnd") long.TryParse(v, out hv);
                else if (k == "tab") tab = v;
                else if (k == "dry") dry = v == "1";
            }
        }
        log += "uri: " + uri + "\n";

        IntPtr target = IntPtr.Zero;
        AutomationElement hit = null;
        if (!string.IsNullOrEmpty(tab))
        {
            string want = Norm(tab);
            IntPtr w = IntPtr.Zero;
            while (hit == null && (w = FindWindowEx(IntPtr.Zero, w, WT_CLASS, null)) != IntPtr.Zero)
            {
                hit = FindTab(w, want);
                if (hit != null) target = w;
            }
            log += hit != null ? "tab match in window " + target + ": " + hit.Current.Name + "\n" : "no tab named: " + want + "\n";
        }
        if (target == IntPtr.Zero && hv != 0 && IsWindow(new IntPtr(hv)))
        {
            target = new IntPtr(hv);
            log += "fallback to window " + hv + "\n";
        }
        if (target == IntPtr.Zero) { log += "nothing to focus\n"; return; }
        if (dry) { log += "dry run, no focus change\n"; return; }

        if (IsIconic(target)) ShowWindow(target, 9);
        if (hit != null)
        {
            object p;
            if (hit.TryGetCurrentPattern(SelectionItemPattern.Pattern, out p)) ((SelectionItemPattern)p).Select();
        }
        if (!SetForegroundWindow(target) || GetForegroundWindow() != target)
        {
            keybd_event(0x12, 0, 0, UIntPtr.Zero);   // an Alt tap lifts Windows' foreground lock
            keybd_event(0x12, 0, 2, UIntPtr.Zero);
            SetForegroundWindow(target);
        }
        if (GetForegroundWindow() != target) SwitchToThisWindow(target, true);
        log += "foreground ok: " + (GetForegroundWindow() == target) + "\n";
    }

    static AutomationElement FindTab(IntPtr w, string want)
    {
        try
        {
            var tabs = AutomationElement.FromHandle(w).FindAll(TreeScope.Descendants,
                new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.TabItem));
            foreach (AutomationElement t in tabs)
                if (Norm(t.Current.Name) == want) return t;
        }
        catch (Exception ex) { log += "uia " + w + ": " + ex.Message + "\n"; }
        return null;
    }

    // Claude Code prefixes tab titles with a status glyph ("✳ ", "◐ "); compare on the name alone.
    public static string Norm(string s)
    {
        return Regex.Replace(s ?? "", @"^[^\p{L}\p{N}]+", "").Trim();
    }
}
