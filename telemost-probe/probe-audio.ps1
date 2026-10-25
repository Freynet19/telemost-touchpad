# READ-ONLY: lists WASAPI audio sessions (per active render/capture endpoint) with owning process, state,
# per-session mute flag, volume and peak level, plus the endpoint-level mute flag. It never calls any Set* method.
param([string]$ProcessFilter = '')

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Probe
{
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorCom { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int Item(uint index, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        [PreserveSig] int OpenPropertyStore(int access, out IntPtr properties);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out int state);
    }

    [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionManager2
    {
        [PreserveSig] int GetAudioSessionControl(IntPtr groupId, int flags, out IntPtr ctl);
        [PreserveSig] int GetSimpleAudioVolume(IntPtr groupId, int flags, out IntPtr vol);
        [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator e);
    }

    [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionEnumerator
    {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int GetSession(int index, out IAudioSessionControl2 session);
    }

    [ComImport, Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionControl2
    {
        [PreserveSig] int GetState(out int state);
        [PreserveSig] int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string name);
        [PreserveSig] int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string name, ref Guid ctx);
        [PreserveSig] int GetIconPath([MarshalAs(UnmanagedType.LPWStr)] out string path);
        [PreserveSig] int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string path, ref Guid ctx);
        [PreserveSig] int GetGroupingParam(out Guid g);
        [PreserveSig] int SetGroupingParam(ref Guid g, ref Guid ctx);
        [PreserveSig] int RegisterAudioSessionNotification(IntPtr n);
        [PreserveSig] int UnregisterAudioSessionNotification(IntPtr n);
        [PreserveSig] int GetSessionIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetSessionInstanceIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetProcessId(out uint pid);
        [PreserveSig] int IsSystemSoundsSession();
        [PreserveSig] int SetDuckingPreference(bool opt);
    }

    [ComImport, Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ISimpleAudioVolume
    {
        [PreserveSig] int SetMasterVolume(float level, ref Guid ctx);
        [PreserveSig] int GetMasterVolume(out float level);
        [PreserveSig] int SetMute(bool mute, ref Guid ctx);
        [PreserveSig] int GetMute(out bool mute);
    }

    [ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioMeterInformation
    {
        [PreserveSig] int GetPeakValue(out float peak);
    }

    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioEndpointVolume
    {
        [PreserveSig] int RegisterControlChangeNotify(IntPtr n);
        [PreserveSig] int UnregisterControlChangeNotify(IntPtr n);
        [PreserveSig] int GetChannelCount(out uint count);
        [PreserveSig] int SetMasterVolumeLevel(float db, ref Guid ctx);
        [PreserveSig] int SetMasterVolumeLevelScalar(float level, ref Guid ctx);
        [PreserveSig] int GetMasterVolumeLevel(out float db);
        [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
        [PreserveSig] int SetChannelVolumeLevel(uint ch, float db, ref Guid ctx);
        [PreserveSig] int SetChannelVolumeLevelScalar(uint ch, float level, ref Guid ctx);
        [PreserveSig] int GetChannelVolumeLevel(uint ch, out float db);
        [PreserveSig] int GetChannelVolumeLevelScalar(uint ch, out float level);
        [PreserveSig] int SetMute(bool mute, ref Guid ctx);
        [PreserveSig] int GetMute(out bool mute);
    }

    public static class AudioProbe
    {
        static readonly Guid IID_SessionMgr2 = new Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F");
        static readonly Guid IID_EndpointVolume = new Guid("5CDF2C82-841E-4546-9722-0CF74078229A");
        static readonly string[] StateNames = { "inactive", "ACTIVE", "expired" };

        public static List<string> Dump(string filter)
        {
            var lines = new List<string>();
            var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorCom();
            foreach (int flow in new[] { 0, 1 }) // 0 = render, 1 = capture
            {
                string flowName = flow == 0 ? "RENDER (speakers)" : "CAPTURE (microphone)";
                IMMDevice def; string defId = "";
                if (enumerator.GetDefaultAudioEndpoint(flow, 1, out def) == 0) def.GetId(out defId);

                IMMDeviceCollection devices;
                enumerator.EnumAudioEndpoints(flow, 1 /* DEVICE_STATE_ACTIVE */, out devices);
                uint n; devices.GetCount(out n);
                for (uint i = 0; i < n; i++)
                {
                    IMMDevice dev; devices.Item(i, out dev);
                    string id; dev.GetId(out id);
                    bool isDefault = id == defId;

                    string endpointMute = "?";
                    object ev;
                    Guid iidEv = IID_EndpointVolume;
                    if (dev.Activate(ref iidEv, 23, IntPtr.Zero, out ev) == 0)
                    {
                        bool m; ((IAudioEndpointVolume)ev).GetMute(out m); endpointMute = m ? "MUTED" : "not muted";
                    }
                    lines.Add(string.Format("== {0}  endpoint {1}{2}  endpoint-mute={3}", flowName, id.Substring(Math.Max(0, id.Length - 38)), isDefault ? " [DEFAULT]" : "", endpointMute));

                    object mgrObj;
                    Guid iid = IID_SessionMgr2;
                    if (dev.Activate(ref iid, 23, IntPtr.Zero, out mgrObj) != 0) continue;
                    var mgr = (IAudioSessionManager2)mgrObj;
                    IAudioSessionEnumerator sessions;
                    if (mgr.GetSessionEnumerator(out sessions) != 0) continue;
                    int count; sessions.GetCount(out count);
                    for (int s = 0; s < count; s++)
                    {
                        IAudioSessionControl2 ctl;
                        if (sessions.GetSession(s, out ctl) != 0) continue;
                        uint pid; ctl.GetProcessId(out pid);
                        string pname = "?";
                        try { pname = pid == 0 ? "(system sounds)" : Process.GetProcessById((int)pid).ProcessName; } catch { }
                        if (filter.Length > 0 && pname.IndexOf(filter, StringComparison.OrdinalIgnoreCase) < 0) continue;
                        int state; ctl.GetState(out state);
                        string disp; ctl.GetDisplayName(out disp);
                        string sid; ctl.GetSessionIdentifier(out sid);
                        string mute = "?", vol = "?";
                        var sv = ctl as ISimpleAudioVolume;
                        if (sv != null)
                        {
                            bool m; float v; sv.GetMute(out m); sv.GetMasterVolume(out v);
                            mute = m ? "MUTED" : "not muted"; vol = (v * 100).ToString("0") + "%";
                        }
                        float peakMax = 0;
                        var meter = ctl as IAudioMeterInformation;
                        if (meter != null)
                        {
                            for (int k = 0; k < 10; k++)
                            {
                                float p; if (meter.GetPeakValue(out p) == 0 && p > peakMax) peakMax = p;
                                System.Threading.Thread.Sleep(50);
                            }
                        }
                        lines.Add(string.Format("   pid={0,-6} {1,-26} state={2,-8} session-mute={3,-9} vol={4,-5} peak(0.5s)={5:0.000}  name='{6}'",
                            pid, pname, StateNames[Math.Min(2, Math.Max(0, state))], mute, vol, peakMax, disp));
                    }
                }
            }
            return lines;
        }
    }
}
'@

[Probe.AudioProbe]::Dump($ProcessFilter)
