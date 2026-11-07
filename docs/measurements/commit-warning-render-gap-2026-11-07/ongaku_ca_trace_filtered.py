import lldb,time,os,tempfile

def trace(debugger, command, result, internal_dict):
    root=tempfile.mkdtemp(prefix='OngakuLayoutTrace-',dir=os.environ.get('TMPDIR',tempfile.gettempdir()))
    open('/private/tmp/ongaku-ca-commit-trace-root.txt','w').write(root)
    debugger.SetAsync(True)
    target=debugger.CreateTarget('/private/tmp/OngakuDesktop-NodeStopBuild/Build/Products/Debug/OngakuDesktop.app/Contents/MacOS/OngakuDesktop')
    bp=target.BreakpointCreateByName('NSCGSTransactionCreatedDuringCommitError')
    info=lldb.SBLaunchInfo(['--ongaku-qualification-root',root,'--ongaku-qualification-prepare','2'])
    info.SetLaunchFlags(lldb.eLaunchFlagDebug)
    info.AddOpenFileAction(1, '/private/tmp/ongaku-ca-commit-trace-app.log', False, True)
    info.AddOpenFileAction(2, '/private/tmp/ongaku-ca-commit-trace-app-error.log', False, True)
    error=lldb.SBError();process=target.Launch(info,error)
    result.AppendMessage('launch='+str(error)+' root='+root)
    hit=False
    ignored=0
    if error.Success():
        started=time.monotonic()
        deadline=started+35
        while time.monotonic()<deadline:
            state=process.GetState()
            if state==lldb.eStateStopped:
                for thread in process:
                    if thread.GetStopReason()==lldb.eStopReasonBreakpoint:
                        names=[frame.GetFunctionName() or '' for frame in thread]
                        if not any(('transaction' in name.lower() or 'commit' in name.lower()) for name in names[1:]):
                            ignored+=1
                            continue
                        hit=True
                        result.AppendMessage('CA_COMMIT_CANDIDATE_STACK')
                        for i,frame in enumerate(thread):
                            if i>=90:break
                            line=frame.GetLineEntry()
                            result.AppendMessage('#%d %s %s:%s' %(i,frame.GetFunctionName(),line.GetFileSpec(),line.GetLine()))
                if hit:break
                process.Continue()
            if state in [lldb.eStateExited,lldb.eStateCrashed,lldb.eStateDetached]:
                result.AppendMessage('state='+str(state));break
            time.sleep(.05)
        result.AppendMessage('observedSeconds=%.2f breakpointLocations=%d lastState=%d' % (time.monotonic()-started,bp.GetNumLocations(),process.GetState()))
        process.Kill()
    result.AppendMessage('candidateHit='+str(hit)+' unrelatedMarkerStops='+str(ignored))
