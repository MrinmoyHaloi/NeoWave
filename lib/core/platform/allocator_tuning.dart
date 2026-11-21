import 'dart:ffi';
import 'dart:io';

/// Freeze glibc's *dynamic* `mmap` / `trim` thresholds at their defaults.
///
/// libmpv allocates multi-MB buffers on every track open (demuxer cache,
/// back buffer, decoder pools). With the default 128 KiB `mmap_threshold`
/// those are `mmap`'d and returned to the OS on free. But freeing an
/// `mmap`'d block raises both thresholds to that block's size, so after the
/// first big buffer every later one is served from the heap, which then
/// grows to the largest buffer ever requested and is kept for the run.
/// Observed: +80 MB RSS per track change (`RssAnon` 94 → 405 MB) while the
/// Dart heap stayed flat, so it is playback-driven native churn.
///
/// `mallopt` sets both values and disables the adaptation, so large buffers
/// are `mmap`'d and returned again. The cost is extra syscalls per track,
/// not per frame; small allocations are unaffected.
///
/// Linux-only and best-effort: a no-op elsewhere or on libcs without
/// `mallopt` (musl). To revert, delete the call in `main.dart`.
void applyAllocatorTuning() {
  if (_applied) return;
  _applied = true;
  if (!Platform.isLinux) return;
  try {
    final mallopt = DynamicLibrary.process()
        .lookupFunction<_MalloptNative, _MalloptDart>('mallopt');
    // Exactly glibc's own starting values — this freezes them rather than
    // moving them, so small-allocation behaviour is unchanged.
    const threshold = 128 * 1024;
    const trimThreshold = -1;
    const mmapThreshold = -3;
    _succeeded = mallopt(trimThreshold, threshold) != 0 &&
        mallopt(mmapThreshold, threshold) != 0;
  } catch (_) {
    // Not glibc, or the symbol is not exported — leave the allocator
    // exactly as it was.
  }
}

/// Whether [applyAllocatorTuning] actually reached a libc `mallopt`
/// (Linux + glibc only). Nothing branches on this at runtime; it exists
/// so the binding can be asserted instead of assumed.
bool get allocatorTuningApplied => _succeeded;

bool _applied = false;
bool _succeeded = false;

typedef _MalloptNative = Int32 Function(Int32, Int32);
typedef _MalloptDart = int Function(int, int);

typedef _SetProcessWorkingSetSizeNative = Int32 Function(IntPtr, IntPtr, IntPtr);
typedef _SetProcessWorkingSetSizeDart = int Function(int, int, int);

/// Proactively release idle/uncommitted native CRT, media_kit buffer, and Direct3D
/// pages back to the operating system.
///
/// On Windows, the OS Heap Manager retains peak working set pages indefinitely
/// after large media buffer frees. Invoking SetProcessWorkingSetSize(-1, -1) flushes
/// idle pages back to the OS without terminating any handles.
/// On Linux, invokes malloc_trim(0).
void trimProcessMemory() {
  if (Platform.isWindows) {
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final setWorkingSet = kernel32.lookupFunction<
          _SetProcessWorkingSetSizeNative,
          _SetProcessWorkingSetSizeDart>('SetProcessWorkingSetSize');
      // Pass pseudo-handle GetCurrentProcess() (-1) with -1, -1 to trim working set
      setWorkingSet(-1, -1, -1);
    } catch (_) {}
  } else if (Platform.isLinux) {
    try {
      final mallocTrim = DynamicLibrary.process()
          .lookupFunction<Int32 Function(IntPtr), int Function(int)>('malloc_trim');
      mallocTrim(0);
    } catch (_) {}
  }
}
