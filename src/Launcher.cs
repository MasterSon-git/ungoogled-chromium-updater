using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

// Older updater versions compile this file alone. PowerShell compiles the Shell interop below.
#if !SHORTCUT_ONLY
using System.Diagnostics;
using System.Reflection;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Forms;

[assembly: AssemblyTitle("Chromium Updater")]

internal static class Launcher
{
    [DllImport("user32.dll", ExactSpelling = true)]
    private static extern short GetAsyncKeyState(int virtualKey);

    [STAThread]
    private static void Main(string[] args)
    {
        try
        {
            LauncherIdentity.InitializeProcess();
            string app = AppDomain.CurrentDomain.BaseDirectory;
            string shell = File.ReadAllText(Path.Combine(app, "pwsh.path")).Trim();
            string script = Path.Combine(app, "Update.ps1");
            string payload = Convert.ToBase64String(Encoding.UTF8.GetBytes(new JavaScriptSerializer().Serialize(args)));
            string command = "-NoLogo -NoProfile -File \"" + script + "\" -Payload " + payload;
            var dispatch = new ProcessStartInfo(shell, "-NonInteractive " + command + " -Dispatch");
            dispatch.UseShellExecute = false;
            dispatch.CreateNoWindow = true;
            dispatch.WorkingDirectory = Environment.CurrentDirectory;
            bool extensionActions = GetAsyncKeyState((int)Keys.ShiftKey) < 0;
            if (!extensionActions)
            {
                using (Process worker = Process.Start(dispatch))
                {
                    worker.WaitForExit();
                    if (worker.ExitCode == 0) return;
                    if (worker.ExitCode != 10) throw new InvalidOperationException();
                }
            }

            var visible = new ProcessStartInfo(shell, command + " -Interactive" + (extensionActions ? " -ExtensionActions" : ""));
            visible.UseShellExecute = true;
            visible.WindowStyle = ProcessWindowStyle.Normal;
            visible.WorkingDirectory = Environment.CurrentDirectory;
            using (Process worker = Process.Start(visible)) { }
        }
        catch
        {
            MessageBox.Show("The Chromium update launcher could not start. Check the installed updater and PowerShell.",
                "Chromium Updater", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
#endif

public static class LauncherIdentity
{
    public const string AppId = "MasterSon.UngoogledChromiumUpdater";

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

    public static void InitializeProcess()
    {
        // Keep the browser launch available if the Shell cannot set the identity.
        SetCurrentProcessExplicitAppUserModelID(AppId);
    }

    public static void CreateShortcut(string path, string launcher, string browser)
    {
        var instance = new ShellLink();
        try
        {
            var link = (IShellLinkW)instance;
            link.SetPath(launcher);
            link.SetDescription("Check for updates and launch Chromium");
            link.SetWorkingDirectory(Path.GetDirectoryName(browser));
            link.SetIconLocation(browser, 0);

            var properties = (IPropertyStore)instance;
            // PKEY_AppUserModel_ID and its VT_LPWSTR value.
            var key = new PropertyKey { FormatId = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), Id = 5 };
            var value = new PropVariant { Type = 31, String = Marshal.StringToCoTaskMemUni(AppId) };
            try
            {
                properties.SetValue(ref key, ref value);
                properties.Commit();
            }
            finally { Marshal.FreeCoTaskMem(value.String); }

            ((IPersistFile)instance).Save(path, false);
        }
        finally { Marshal.ReleaseComObject(instance); }
    }

    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    private class ShellLink { }

    [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellLinkW
    {
        // Unused methods reserve their positions in the IShellLinkW vtable.
        void GetPath();
        void GetIDList();
        void SetIDList();
        void GetDescription();
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string description);
        void GetWorkingDirectory();
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string directory);
        void GetArguments();
        void SetArguments();
        void GetHotkey();
        void SetHotkey();
        void GetShowCmd();
        void SetShowCmd();
        void GetIconLocation();
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string icon, int index);
        void SetRelativePath();
        void Resolve();
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string path);
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPropertyStore
    {
        void GetCount();
        void GetAt();
        void GetValue();
        void SetValue(ref PropertyKey key, ref PropVariant value);
        void Commit();
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PropertyKey
    {
        public Guid FormatId;
        public uint Id;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct PropVariant
    {
        [FieldOffset(0)] public ushort Type;
        [FieldOffset(8)] public IntPtr String;
        // The counted array member gives the native union its size on x86 and x64.
        [FieldOffset(8)] private CountedArray array;

        [StructLayout(LayoutKind.Sequential)]
        private struct CountedArray
        {
            public uint Count;
            public IntPtr Values;
        }
    }
}
