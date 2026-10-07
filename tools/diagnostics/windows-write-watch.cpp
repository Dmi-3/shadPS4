// SPDX-License-Identifier: GPL-2.0-or-later
// Standalone Windows write watch. Does not change guest memory or handle guest exceptions.
#include <windows.h>
#include <chrono>
#include <cstdio>
#include <cwchar>
#include <map>
#include <string>

static std::wstring Quote(const wchar_t* arg) {
    std::wstring result = L"\"";
    unsigned slashes = 0;
    for (const wchar_t* p = arg; *p; ++p) {
        if (*p == L'\\') { ++slashes; continue; }
        if (*p == L'\"') { result.append(slashes * 2 + 1, L'\\'); }
        else { result.append(slashes, L'\\'); }
        slashes = 0;
        result += *p;
    }
    result.append(slashes * 2, L'\\');
    return result + L"\"";
}
static bool Watch(HANDLE thread, unsigned long long address, bool enable) {
    CONTEXT context{};
    context.ContextFlags = CONTEXT_DEBUG_REGISTERS;
    if (!GetThreadContext(thread, &context)) return false;
    context.Dr0 = enable ? address : 0;
    context.Dr6 = 0;
    context.Dr7 = (context.Dr7 & ~0xF0003ULL) | (enable ? 0xD0001ULL : 0);
    return SetThreadContext(thread, &context) != FALSE;
}
static bool Read(HANDLE process, unsigned long long address, void* out, SIZE_T size) {
    SIZE_T copied{};
    return ReadProcessMemory(process, reinterpret_cast<const void*>(address), out, size, &copied)
           && copied == size;
}
int wmain(int argc, wchar_t** argv) {
    if (argc < 4) { std::fprintf(stderr,"Usage: write-watch ADDRESS EXE LOG [arguments...]\n"); return 2; }
    wchar_t* end{};
    const auto address = std::wcstoull(argv[1], &end, 0);
    if (!address || *end || (address & 3) || address > 0x7FFFFFFFFFFFULL) return 2;
    FILE* log{};
    if (_wfopen_s(&log,argv[3],L"w") || !log) return 3;
    setvbuf(log,nullptr,_IONBF,0);
    std::wstring command = Quote(argv[2]);
    for (int i=4;i<argc;++i) command += L" " + Quote(argv[i]);
    STARTUPINFOW startup{}; startup.cb=sizeof(startup);
    PROCESS_INFORMATION process{};
    if (!CreateProcessW(argv[2],command.data(),nullptr,nullptr,FALSE,DEBUG_ONLY_THIS_PROCESS,
                        nullptr,nullptr,&startup,&process)) {
        std::fprintf(log,"launch failed error=%lu\n",GetLastError()); std::fclose(log); return 4;
    }
    DebugSetProcessKillOnExit(FALSE);

    std::map<DWORD,HANDLE> threads;
    bool initial_break = false, stop = false, exited = false, cleared = false;
    unsigned hits = 0;
    const auto deadline = std::chrono::steady_clock::now()+std::chrono::minutes(4);
    bool timeout_requested = false;
    std::fprintf(log,"pid=%lu watch=%llx width=4 timeout_seconds=240\n",process.dwProcessId,address);
    while (!stop) {
        DEBUG_EVENT event{};
        if (!WaitForDebugEvent(&event,1000)) {
            if (GetLastError()!=ERROR_SEM_TIMEOUT) { std::fprintf(log,"wait failed=%lu\n",GetLastError()); break; }
            if (!timeout_requested && std::chrono::steady_clock::now()>deadline) {
                timeout_requested=true;
                if (!DebugBreakProcess(process.hProcess)) { std::fprintf(log,"timeout break failed\n"); break; }
            }
            continue;
        }
        DWORD disposition=DBG_CONTINUE;
        if (event.dwDebugEventCode==CREATE_PROCESS_DEBUG_EVENT) {
            threads[event.dwThreadId]=event.u.CreateProcessInfo.hThread;
            if(process.hThread!=event.u.CreateProcessInfo.hThread) CloseHandle(process.hThread);
            process.hThread=nullptr;
            if(event.u.CreateProcessInfo.hFile) CloseHandle(event.u.CreateProcessInfo.hFile);
            if(event.u.CreateProcessInfo.hProcess && event.u.CreateProcessInfo.hProcess!=process.hProcess)
                CloseHandle(event.u.CreateProcessInfo.hProcess);
            if(!Watch(threads[event.dwThreadId],address,true)) { std::fprintf(log,"initial watch failed=%lu\n",GetLastError()); stop=true; }
        } else if (event.dwDebugEventCode==CREATE_THREAD_DEBUG_EVENT) {
            threads[event.dwThreadId]=event.u.CreateThread.hThread;
            if(!Watch(threads[event.dwThreadId],address,true)) { std::fprintf(log,"thread watch failed=%lu\n",GetLastError()); stop=true; }
        } else if(event.dwDebugEventCode==EXIT_THREAD_DEBUG_EVENT) {
            auto thread=threads.find(event.dwThreadId);
            if(thread!=threads.end()) { CloseHandle(thread->second); threads.erase(thread); }
        } else if(event.dwDebugEventCode==LOAD_DLL_DEBUG_EVENT) {
            if(event.u.LoadDll.hFile) CloseHandle(event.u.LoadDll.hFile);
        } else if(event.dwDebugEventCode==EXIT_PROCESS_DEBUG_EVENT) {
            std::fprintf(log,"process exited code=%lu\n",event.u.ExitProcess.dwExitCode); stop=exited=true;
        } else if(event.dwDebugEventCode==EXCEPTION_DEBUG_EVENT) {
            const auto code=event.u.Exception.ExceptionRecord.ExceptionCode;
            disposition=DBG_EXCEPTION_NOT_HANDLED;
            if(code==EXCEPTION_BREAKPOINT && (!initial_break || timeout_requested)) {
                initial_break=true; disposition=DBG_CONTINUE;
                if(timeout_requested) { std::fprintf(log,"watch timed out without NaN write\n"); stop=true; }
            } else if(code==EXCEPTION_SINGLE_STEP && threads.count(event.dwThreadId)) {
                CONTEXT c{}; c.ContextFlags=CONTEXT_ALL;
                if(GetThreadContext(threads[event.dwThreadId],&c) && (c.Dr6&1)) {
                    disposition=DBG_CONTINUE;
                    DWORD values[3]{};
                    const bool read=Read(process.hProcess,address,values,sizeof(values));
                    ++hits;
                    const bool nan=read && (values[0]&0x7F800000U)==0x7F800000U && (values[0]&0x7FFFFFU);
                    if(hits<=16 || nan) {
                        std::fprintf(log,"hit=%u thread=%lu rip=%llx read=%d words=%08lx,%08lx,%08lx\n",
                                     hits,event.dwThreadId,c.Rip,read,values[0],values[1],values[2]);
                    }
                    if(nan) {
                        std::fprintf(log,"rax=%llx rbx=%llx rcx=%llx rdx=%llx rsi=%llx rdi=%llx rsp=%llx rbp=%llx r8=%llx r9=%llx\n",
                                     c.Rax,c.Rbx,c.Rcx,c.Rdx,c.Rsi,c.Rdi,c.Rsp,c.Rbp,c.R8,c.R9);
                        BYTE bytes[96]{};
                        if(Read(process.hProcess,c.Rip-48,bytes,sizeof(bytes))) {
                            std::fprintf(log,"code_at=%llx ",c.Rip-48);
                            for(auto b:bytes) std::fprintf(log,"%02x",b);
                            std::fputc('\n',log);
                        }
                        unsigned long long stack[16]{};
                        if(Read(process.hProcess,c.Rsp,stack,sizeof(stack))) {
                            std::fprintf(log,"stack:"); for(auto s:stack) std::fprintf(log," %llx",s); std::fputc('\n',log);
                        }
                        std::fprintf(log,"first NaN write captured; clearing watch and detaching\n"); stop=true;
                    }
                    if(hits>=512) { std::fprintf(log,"write hit limit reached\n"); stop=true; }
                    c.ContextFlags=CONTEXT_DEBUG_REGISTERS; c.Dr6=0;
                    if(!SetThreadContext(threads[event.dwThreadId],&c)) stop=true;
                }
            }
        }
        if(stop && !exited) {
            cleared=true;
            for(auto [id,thread]:threads) if(!Watch(thread,address,false)) std::fprintf(log,"clear failed thread=%lu error=%lu\n",id,GetLastError());
        }
        if(!ContinueDebugEvent(event.dwProcessId,event.dwThreadId,disposition)) {
            std::fprintf(log,"continue failed=%lu\n",GetLastError()); break;
        }
    }
    if(!exited && !cleared) {
        for(auto [id,thread]:threads) {
            if(SuspendThread(thread)!=DWORD(-1)) {
                Watch(thread,address,false); ResumeThread(thread);
            }
        }
    }
    if(!exited) std::fprintf(log,"detach=%d\n",DebugActiveProcessStop(process.dwProcessId)!=FALSE);
    for(auto [id,thread]:threads) CloseHandle(thread);
    CloseHandle(process.hProcess); std::fclose(log);
    return hits ? 0 : 5;
}
