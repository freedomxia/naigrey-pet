// Windows-only source. No keyboard payload is dereferenced and no audio buffer is opened.
// stdout protocol: normalized sensor samples or {id, startedAt} process-identity replies.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

internal static class Program {
    private delegate IntPtr KeyboardCallback(int code, IntPtr message, IntPtr payload);
    [DllImport("user32.dll", SetLastError=true)] private static extern IntPtr SetWindowsHookEx(int id, KeyboardCallback callback, IntPtr module, uint thread);
    [DllImport("user32.dll")] private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr message, IntPtr payload);
    [DllImport("user32.dll")] private static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] private static extern IntPtr GetModuleHandle(string name);
    private static readonly KeyboardCallback callback = OnKeyboard;
    private static IntPtr hook;
    private static long lastKey = -1;
    private static readonly Stopwatch clock = Stopwatch.StartNew();
    private static readonly object outputLock = new object();
    private static readonly HashSet<int> excluded = new HashSet<int>();
    private static string ownApplicationName;

    private static IntPtr OnKeyboard(int code, IntPtr message, IntPtr payload) {
        // WM_KEYDOWN / WM_SYSKEYDOWN only. Never marshal or inspect KBDLLHOOKSTRUCT.
        if (code >= 0 && (message.ToInt64() == 0x100 || message.ToInt64() == 0x104))
            Interlocked.Exchange(ref lastKey, clock.ElapsedTicks);
        return CallNextHookEx(hook, code, message, payload);
    }
    private static double? ProcessStart(int pid) {
        try { using (Process p=Process.GetProcessById(pid)) { return (p.StartTime.ToUniversalTime()-new DateTime(1970,1,1,0,0,0,DateTimeKind.Utc)).TotalMilliseconds; } }
        catch { return null; }
    }
    private static void Write(object value) {
        try { lock(outputLock) { Console.WriteLine(new JavaScriptSerializer().Serialize(value)); Console.Out.Flush(); } }
        catch { Environment.Exit(0); }
    }
    private static void ReadRequests() {
        // Input originates only from our parent. Cap input before parsing.
        while (true) {
            var line = new System.Text.StringBuilder();
            int ch;
            while ((ch=Console.Read()) != -1 && ch != '\n') { if(line.Length>=1024) Environment.Exit(2); line.Append((char)ch); }
            if(ch == -1) Environment.Exit(0); // Pipe closed: never orphan the hook.
            try {
                var json=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(line.ToString());
                object idValue,pidValue; int id,pid;
                if(json.TryGetValue("id",out idValue) && json.TryGetValue("pid",out pidValue)
                    && Int32.TryParse(Convert.ToString(idValue,CultureInfo.InvariantCulture),out id)
                    && Int32.TryParse(Convert.ToString(pidValue,CultureInfo.InvariantCulture),out pid) && id>0 && pid>0)
                    Write(new {id=id,startedAt=ProcessStart(pid)});
            } catch { /* Invalid input has no side effect and no raw error output. */ }
        }
    }
    internal static bool Excluded(uint pid) {
        if(pid==0 || pid>Int32.MaxValue || excluded.Contains((int)pid)) return true;
        // Electron media can run in a child utility process. The executable name
        // matches the parent product, so muted pet players cannot count as music.
        if(ownApplicationName!=null) try { using(var p=Process.GetProcessById((int)pid)) { if(p.ProcessName==ownApplicationName) return true; } } catch {}
        return false;
    }
    [STAThread]
    private static int Main(string[] args) {
        bool selfTest=Array.IndexOf(args,"--self-test")>=0;
        excluded.Add(Process.GetCurrentProcess().Id);
        foreach(string arg in args) { int pid;if(Int32.TryParse(arg,out pid)&&pid>0) { excluded.Add(pid);if(ownApplicationName==null)try{using(var p=Process.GetProcessById(pid)){ownApplicationName=p.ProcessName;}}catch{} } }
        hook=SetWindowsHookEx(13,callback,GetModuleHandle(null),0);
        if(selfTest) {
            bool? audio=null;
            var probe=new Thread(delegate(){audio=AudioActivity.Read();});probe.IsBackground=true;probe.SetApartmentState(ApartmentState.MTA);probe.Start();
            if(!probe.Join(5000)) return 2;
            Write(new {selfTest=true,keyboardAvailable=hook!=IntPtr.Zero,audioAvailable=audio.HasValue,processStartedAt=ProcessStart(Process.GetCurrentProcess().Id)});
            if(hook!=IntPtr.Zero)UnhookWindowsHookEx(hook);
            return 0;
        }
        var input=new Thread(ReadRequests);input.IsBackground=true;input.Start();
        // A dedicated MTA thread queries Core Audio. The keyboard hook thread
        // only maintains its message loop and timestamps; it never blocks on COM.
        var samples=new Thread(delegate() {
            while(true) {
                long tick=Interlocked.Read(ref lastKey);
                double? age=tick<0 ? (double?)null : Math.Max(0,(double)(clock.ElapsedTicks-tick)/Stopwatch.Frequency);
                Write(new {type="senses",keyboardAvailable=hook!=IntPtr.Zero,keyAge=age,audioActive=AudioActivity.Read()});
                Thread.Sleep(250);
            }
        });samples.IsBackground=true;samples.SetApartmentState(ApartmentState.MTA);samples.Start();
        try { Application.Run(); } finally { if(hook!=IntPtr.Zero)UnhookWindowsHookEx(hook); }
        return 0;
    }
}

internal static class AudioActivity {
    private static void Release(object value) { if(value!=null && Marshal.IsComObject(value)) Marshal.ReleaseComObject(value); }
    internal static bool? Read() {
        IMMDeviceEnumerator devices=null;IMMDevice device=null;IAudioSessionManager2 manager=null;IAudioSessionEnumerator sessions=null;
        try {
            devices=(IMMDeviceEnumerator)new MMDeviceEnumerator();
            if(devices.GetDefaultAudioEndpoint(0,1,out device)<0) return null; // render, multimedia
            object activated;Guid iid=typeof(IAudioSessionManager2).GUID;
            if(device.Activate(ref iid,23,IntPtr.Zero,out activated)<0)return null;
            manager=(IAudioSessionManager2)activated;
            if(manager.GetSessionEnumerator(out sessions)<0)return null;
            int count;if(sessions.GetCount(out count)<0)return null;
            for(int i=0;i<Math.Min(count,1024);i++) {
                IAudioSessionControl control=null;
                try {
                    if(sessions.GetSession(i,out control)<0)continue;
                    var session=(IAudioSessionControl2)control;
                    int state;uint pid;
                    if(session.GetState(out state)<0 || state!=1 || session.GetProcessId(out pid)<0 || Program.Excluded(pid))continue;
                    if(session.IsSystemSoundsSession()==0)continue;
                    var volume=(ISimpleAudioVolume)session;bool mute;float level;
                    if(volume.GetMute(out mute)<0 || volume.GetMasterVolume(out level)<0 || mute || level<=0)continue;
                    return true;
                } catch { /* One disappearing session does not invalidate siblings. */ }
                finally { Release(control); }
            }
            return false;
        } catch { return null; }
        finally { Release(sessions);Release(manager);Release(device);Release(devices); }
    }
}

[ComImport,Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] internal class MMDeviceEnumerator {}
[ComImport,Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMMDeviceEnumerator {
    [PreserveSig]int EnumAudioEndpoints(int flow,uint mask,out IntPtr collection);
    [PreserveSig]int GetDefaultAudioEndpoint(int flow,int role,out IMMDevice device);
    [PreserveSig]int GetDevice([MarshalAs(UnmanagedType.LPWStr)]string id,out IMMDevice device);
    [PreserveSig]int RegisterEndpointNotificationCallback(IntPtr callback);
    [PreserveSig]int UnregisterEndpointNotificationCallback(IntPtr callback);
}
[ComImport,Guid("D666063F-1587-4E43-81F1-B948E807363F"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMMDevice {
    [PreserveSig]int Activate(ref Guid iid,uint context,IntPtr parameters,[MarshalAs(UnmanagedType.IUnknown)]out object value);
    [PreserveSig]int OpenPropertyStore(uint access,out IntPtr store);
    [PreserveSig]int GetId([MarshalAs(UnmanagedType.LPWStr)]out string id);
    [PreserveSig]int GetState(out uint state);
}
[ComImport,Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAudioSessionManager2 {
    [PreserveSig]int GetAudioSessionControl(IntPtr session,uint flags,out IntPtr control);
    [PreserveSig]int GetSimpleAudioVolume(IntPtr session,uint flags,out IntPtr volume);
    [PreserveSig]int GetSessionEnumerator(out IAudioSessionEnumerator enumerator);
    [PreserveSig]int RegisterSessionNotification(IntPtr notification);
    [PreserveSig]int UnregisterSessionNotification(IntPtr notification);
    [PreserveSig]int RegisterDuckNotification([MarshalAs(UnmanagedType.LPWStr)]string id,IntPtr notification);
    [PreserveSig]int UnregisterDuckNotification(IntPtr notification);
}
[ComImport,Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAudioSessionEnumerator {
    [PreserveSig]int GetCount(out int count);
    [PreserveSig]int GetSession(int index,out IAudioSessionControl session);
}
[ComImport,Guid("F4B1A599-7266-4319-A8CA-E70ACB11E8CD"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAudioSessionControl {
    [PreserveSig]int GetState(out int state);
    [PreserveSig]int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)]out string name);
    [PreserveSig]int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)]string name,IntPtr context);
    [PreserveSig]int GetIconPath([MarshalAs(UnmanagedType.LPWStr)]out string path);
    [PreserveSig]int SetIconPath([MarshalAs(UnmanagedType.LPWStr)]string path,IntPtr context);
    [PreserveSig]int GetGroupingParam(out Guid grouping);
    [PreserveSig]int SetGroupingParam(ref Guid grouping,IntPtr context);
    [PreserveSig]int RegisterAudioSessionNotification(IntPtr client);
    [PreserveSig]int UnregisterAudioSessionNotification(IntPtr client);
}
[ComImport,Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAudioSessionControl2 {
    [PreserveSig]int GetState(out int state);
    [PreserveSig]int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)]out string name);
    [PreserveSig]int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)]string name,IntPtr context);
    [PreserveSig]int GetIconPath([MarshalAs(UnmanagedType.LPWStr)]out string path);
    [PreserveSig]int SetIconPath([MarshalAs(UnmanagedType.LPWStr)]string path,IntPtr context);
    [PreserveSig]int GetGroupingParam(out Guid grouping);
    [PreserveSig]int SetGroupingParam(ref Guid grouping,IntPtr context);
    [PreserveSig]int RegisterAudioSessionNotification(IntPtr client);
    [PreserveSig]int UnregisterAudioSessionNotification(IntPtr client);
    [PreserveSig]int GetSessionIdentifier([MarshalAs(UnmanagedType.LPWStr)]out string id);
    [PreserveSig]int GetSessionInstanceIdentifier([MarshalAs(UnmanagedType.LPWStr)]out string id);
    [PreserveSig]int GetProcessId(out uint pid);
    [PreserveSig]int IsSystemSoundsSession();
    [PreserveSig]int SetDuckingPreference([MarshalAs(UnmanagedType.Bool)]bool optOut);
}
[ComImport,Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface ISimpleAudioVolume {
    [PreserveSig]int SetMasterVolume(float level,IntPtr context);
    [PreserveSig]int GetMasterVolume(out float level);
    [PreserveSig]int SetMute([MarshalAs(UnmanagedType.Bool)]bool mute,IntPtr context);
    [PreserveSig]int GetMute([MarshalAs(UnmanagedType.Bool)]out bool mute);
}
