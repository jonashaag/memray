import collections
import contextlib
import os
import pathlib
import sys

cimport cython

import threading
from datetime import datetime

from rich.progress import Progress
from rich.progress import SpinnerColumn

from posix.time cimport CLOCK_MONOTONIC
from posix.time cimport clock_gettime
from posix.time cimport timespec

from _memray.hooks cimport Allocator
from _memray.hooks cimport isDeallocator
from _memray.logging cimport setLogThreshold
from _memray.record_reader cimport RecordReader
from _memray.record_reader cimport RecordResult
from _memray.record_writer cimport RecordWriter
from _memray.records cimport Allocation as _Allocation
from _memray.records cimport MemoryRecord
from _memray.records cimport MemorySnapshot as _MemorySnapshot
from _memray.sink cimport FileSink
from _memray.sink cimport NullSink
from _memray.sink cimport Sink
from _memray.sink cimport SocketSink
from _memray.snapshot cimport AllocationStatsAggregator
from _memray.snapshot cimport HighWatermark
from _memray.snapshot cimport HighWatermarkFinder
from _memray.snapshot cimport Py_GetSnapshotAllocationRecords
from _memray.snapshot cimport Py_ListFromSnapshotAllocationRecords
from _memray.snapshot cimport SnapshotAllocationAggregator
from _memray.socket_reader_thread cimport BackgroundSocketReader
from _memray.source cimport FileSource
from _memray.source cimport SocketSource
from _memray.tracking_api cimport Tracker as NativeTracker
from _memray.tracking_api cimport install_trace_function
from cpython cimport PyErr_CheckSignals
from libc.stdint cimport uint64_t
from libcpp cimport bool
from libcpp.limits cimport numeric_limits
from libcpp.memory cimport make_shared
from libcpp.memory cimport make_unique
from libcpp.memory cimport shared_ptr
from libcpp.memory cimport unique_ptr
from libcpp.string cimport string as cppstring
from libcpp.unordered_map cimport unordered_map
from libcpp.utility cimport move
from libcpp.vector cimport vector

from ._destination import FileDestination
from ._destination import SocketDestination
from ._metadata import Metadata
from ._stats import Stats

include "_memray_test_utils.pyx"


def set_log_level(int level):
    """Configure which log messages will be printed to stderr by memray.

    By default, only log records of severity `logging.WARNING` or higher will
    be printed, but you can adjust this threshold.

    Args:
        level (int): The lowest severity level that a log record can have and
            still be printed.
    """
    setLogThreshold(level)


cpdef enum AllocatorType:
    MALLOC = 1
    FREE = 2
    CALLOC = 3
    REALLOC = 4
    POSIX_MEMALIGN = 5
    ALIGNED_ALLOC = 6
    MEMALIGN = 7
    VALLOC = 8
    PVALLOC = 9
    MMAP = 10
    MUNMAP = 11
    PYMALLOC_MALLOC = 12
    PYMALLOC_CALLOC = 13
    PYMALLOC_REALLOC = 14
    PYMALLOC_FREE = 15

cpdef enum PythonAllocatorType:
    PYTHON_ALLOCATOR_PYMALLOC = 1
    PYTHON_ALLOCATOR_PYMALLOC_DEBUG = 2
    PYTHON_ALLOCATOR_MALLOC = 3
    PYTHON_ALLOCATOR_OTHER = 4

def size_fmt(num, suffix='B'):
    for unit in ['','K','M','G','T','P','E','Z']:
        if abs(num) < 1024.0:
            return f"{num:5.3f}{unit}{suffix}"
        num /= 1024.0
    return f"{num:.1f}Y{suffix}"

# Memray core

PYTHON_VERSION = (sys.version_info.major, sys.version_info.minor)

@cython.freelist(1024)
cdef class AllocationRecord:
    cdef object _tuple
    cdef object _stack_trace
    cdef object _native_stack_trace
    cdef shared_ptr[RecordReader] _reader

    def __init__(self, record):
        self._tuple = record
        self._stack_trace = None

    def __eq__(self, other):
        cdef AllocationRecord _other
        if isinstance(other, AllocationRecord):
            _other = other
            return self._tuple == _other._tuple
        return NotImplemented

    def __hash__(self):
        return hash(self._tuple)

    @property
    def tid(self):
        return self._tuple[0]

    @property
    def address(self):
        return self._tuple[1]

    @property
    def size(self):
        return self._tuple[2]

    @property
    def allocator(self):
        return self._tuple[3]

    @property
    def stack_id(self):
        return self._tuple[4]

    @property
    def n_allocations(self):
        return self._tuple[5]

    @property
    def thread_name(self):
        if self.tid == -1:
            return "merged thread"
        assert self._reader.get() != NULL, "Cannot get thread name without reader."
        cdef object name = self._reader.get().getThreadName(self.tid)
        thread_id = hex(self.tid)
        return f"{thread_id} ({name})" if name else f"{thread_id}"

    def stack_trace(self, max_stacks=None):
        assert self._reader.get() != NULL, "Cannot get stack trace without reader."
        if self._stack_trace is None:
            if self.allocator in (AllocatorType.FREE, AllocatorType.MUNMAP):
                raise NotImplementedError("Stack traces for deallocations aren't captured.")

            if max_stacks is None:
                self._stack_trace = self._reader.get().Py_GetStackFrame(self._tuple[4])
            else:
                self._stack_trace = self._reader.get().Py_GetStackFrame(self._tuple[4], max_stacks)
        return self._stack_trace

    def native_stack_trace(self, max_stacks=None):
        assert self._reader.get() != NULL, "Cannot get stack trace without reader."
        if self._native_stack_trace is None:
            if self.allocator in (AllocatorType.FREE, AllocatorType.MUNMAP):
                raise NotImplementedError("Stack traces for deallocations aren't captured.")

            if max_stacks is None:
                self._native_stack_trace = self._reader.get().Py_GetNativeStackFrame(
                        self._tuple[6], self._tuple[7])
            else:
                self._native_stack_trace = self._reader.get().Py_GetNativeStackFrame(
                        self._tuple[6], self._tuple[7], max_stacks)
        return self._native_stack_trace

    cdef _is_eval_frame(self, object symbol):
        return "_PyEval_EvalFrameDefault" in symbol

    def _pure_python_stack_trace(self, max_stacks):
        for frame in self.stack_trace(max_stacks):
            _, file, _ = frame
            if file.endswith(".pyx"):
                continue
            yield frame

    def hybrid_stack_trace(self, max_stacks=None):
        python_stack = tuple(self._pure_python_stack_trace(max_stacks))
        n_python_frames_left = len(python_stack) if python_stack else None
        python_stack = iter(python_stack)
        for native_frame in self.native_stack_trace(max_stacks):
            if n_python_frames_left == 0:
                break
            symbol, *_ = native_frame
            if self._is_eval_frame(symbol):
                python_frame =  next(python_stack)
                n_python_frames_left -= 1
                yield python_frame
            else:
                yield native_frame

    def __repr__(self):
        return (f"AllocationRecord<tid={hex(self.tid)}, address={hex(self.address)}, "
                f"size={'N/A' if not self.size else size_fmt(self.size)}, allocator={self.allocator!r}, "
                f"allocations={self.n_allocations}>")


MemorySnapshot = collections.namedtuple("MemorySnapshot", "time rss heap")

cdef class Tracker:
    """Context manager for tracking memory allocations in a Python script.

    You can track memory allocations in a Python process by using a Tracker as
    a context manager::

        with memray.Tracker("some_output_file.bin"):

    Any code inside of the ``with`` block will have its allocations tracked.
    Any allocations made by other threads will also be tracked for the duration
    of the ``with`` block. Because of the way tracking works, there can only be
    one tracker active in the entire program at a time. Attempting to activate
    a tracker while one is already active will raise an exception, as will
    attempting to activate the same tracker more than once. If you want to
    re-enable tracking after the ``with`` block ends, you will need to create
    a fresh `Tracker` instance.

    Args:
        file_name (str or pathlib.Path): The name of the file to write the
            captured allocations into. This is the only argument that can be
            passed positionally. If not provided, the *destination* keyword
            argument must be provided.
        destination (FileDestination or SocketDestination): The destination to
            write captured allocations to. If provided, the *file_name*
            argument must not be.
        native_traces (bool): Whether or not to capture native stack frames, in
            addition to Python stack frames (see :ref:`Native Tracking`).
            Defaults to False.
        follow_fork (bool): Whether or not to continue tracking in a subprocess
            that is forked from the tracked process (see :ref:`Tracking across
            Forks`). Defaults to False.
        memory_interval_ms (int): How many milliseconds to wait between sending
            periodic resident set size updates. By default, every 10
            milliseconds a record is written that contains the current
            timestamp and the total number of bytes of virtual memory allocated
            by the process. These records are used to create the graph of
            memory usage over time that appears at the top of the flame graph,
            for instance. This parameter lets you adjust the frequency between
            updates, though you shouldn't need to change it.
    """
    cdef bool _native_traces
    cdef unsigned int _memory_interval_ms
    cdef bool _follow_fork
    cdef bool _trace_python_allocators
    cdef object _previous_profile_func
    cdef object _previous_thread_profile_func
    cdef unique_ptr[RecordWriter] _writer

    cdef unique_ptr[Sink] _make_writer(self, destination) except*:
        # Creating a Sink can raise Python exceptions (if is interrupted by signal
        # handlers). If this happens, this method will propagate the appropriate exception.
        if isinstance(destination, FileDestination):
            is_dev_null = False
            with contextlib.suppress(OSError):
                if pathlib.Path("/dev/null").samefile(destination.path):
                    is_dev_null = True

            if is_dev_null:
                return unique_ptr[Sink](new NullSink())
            return unique_ptr[Sink](new FileSink(os.fsencode(destination.path),
                                                 destination.overwrite,
                                                 destination.compress_on_exit))

        elif isinstance(destination, SocketDestination):
            return unique_ptr[Sink](new SocketSink(destination.address, destination.server_port))
        else:
            raise TypeError("destination must be a SocketDestination or FileDestination")


    def __cinit__(self, object file_name=None, *, object destination=None,
                  bool native_traces=False, unsigned int memory_interval_ms = 10,
                  bool follow_fork=False, bool trace_python_allocators=False):
        if (file_name, destination).count(None) != 1:
            raise TypeError("Exactly one of 'file_name' or 'destination' argument must be specified")

        cdef cppstring command_line = " ".join(sys.argv)
        self._native_traces = native_traces
        self._memory_interval_ms = memory_interval_ms
        self._follow_fork = follow_fork
        self._trace_python_allocators = trace_python_allocators

        if file_name is not None:
            destination = FileDestination(path=file_name)

        if follow_fork and not isinstance(destination, FileDestination):
            raise RuntimeError("follow_fork requires an output file")

        self._writer = make_unique[RecordWriter](
                move(self._make_writer(destination)), command_line, native_traces
            )

    @cython.profile(False)
    def __enter__(self):

        if NativeTracker.getTracker() != NULL:
            raise RuntimeError("No more than one Tracker instance can be active at the same time")

        cdef unique_ptr[RecordWriter] writer
        if self._writer == NULL:
            raise RuntimeError("Attempting to use stale output handle")
        writer = move(self._writer)

        self._previous_profile_func = sys.getprofile()
        self._previous_thread_profile_func = threading._profile_hook
        threading.setprofile(start_thread_trace)

        NativeTracker.createTracker(
            move(writer),
            self._native_traces,
            self._memory_interval_ms,
            self._follow_fork,
            self._trace_python_allocators,
        )
        return self

    @cython.profile(False)
    def __exit__(self, exc_type, exc_value, exc_traceback):
        NativeTracker.destroyTracker()
        sys.setprofile(self._previous_profile_func)
        threading.setprofile(self._previous_thread_profile_func)


def start_thread_trace(frame, event, arg):
    if event in {"call", "c_call"}:
        install_trace_function()
    return start_thread_trace


cdef millis_to_dt(millis):
    return datetime.fromtimestamp(millis // 1000).replace(
        microsecond=millis % 1000 * 1000)


cdef _create_metadata(header, peak_memory):
    stats = header["stats"]
    allocator_id_to_name = {
        PythonAllocatorType.PYTHON_ALLOCATOR_PYMALLOC: "pymalloc",
        PythonAllocatorType.PYTHON_ALLOCATOR_PYMALLOC_DEBUG: "pymalloc debug",
        PythonAllocatorType.PYTHON_ALLOCATOR_MALLOC: "malloc",
        PythonAllocatorType.PYTHON_ALLOCATOR_OTHER: "unknown",
    }
    return Metadata(
        start_time=millis_to_dt(stats["start_time"]),
        end_time=millis_to_dt(stats["end_time"]),
        total_allocations=stats["n_allocations"],
        total_frames=stats["n_frames"],
        peak_memory=peak_memory,
        command_line=header["command_line"],
        pid=header["pid"],
        python_allocator=allocator_id_to_name[header["python_allocator"]],
        has_native_traces=header["native_traces"],
    )


cdef class ProgressIndicator:
    cdef bool _report_progress
    cdef object _indicator
    cdef object _context_manager
    cdef object _task
    cdef object _task_description
    cdef object _total
    cdef size_t _cumulative_num_processed
    cdef size_t _update_interval
    cdef size_t _ns_between_refreshes
    cdef timespec _next_refresh

    def __init__(self,
        str task_description,
        object total,
        bool report_progress=True,
        size_t refresh_per_second=10,
    ):
        self._report_progress = report_progress
        self._total = total
        self._cumulative_num_processed = 0
        # Only check the elapsed time every N records
        self._update_interval = 100_000
        self._ns_between_refreshes = 1_000_000_000 // refresh_per_second
        self._next_refresh.tv_sec = 0
        self._next_refresh.tv_nsec = 0
        self._task_description = task_description
        self._task = None
        self._context_manager = None
        if report_progress:
            self._indicator = Progress(
                SpinnerColumn(),
                *Progress.get_default_columns(),
                auto_refresh=False,
                transient=True,
            )

    def __enter__(self):
        if not self._report_progress:
            return self
        self._context_manager = self._indicator.__enter__()
        self._task = self._context_manager.add_task(
            f"[blue]{self._task_description}...",
            total=self._total
        )
        return self

    def __exit__(self, type, value, traceback):
        if not self._report_progress:
            return
        return self._context_manager.__exit__(type, value, traceback)

    cdef bool _time_for_refresh(self):
        cdef timespec now
        cdef int rc = clock_gettime(CLOCK_MONOTONIC, &now)

        if 0 != rc:
            return True

        if now.tv_sec > self._next_refresh.tv_sec or (
            now.tv_sec == self._next_refresh.tv_sec
            and now.tv_nsec > self._next_refresh.tv_nsec
        ):
            self._next_refresh = now
            self._next_refresh.tv_nsec += self._ns_between_refreshes
            while self._next_refresh.tv_nsec > 1_000_000_000:
                self._next_refresh.tv_nsec -= 1_000_000_000
                self._next_refresh.tv_sec += 1
            return True

        return False

    cdef update(self, size_t n_processed):
        self._cumulative_num_processed += n_processed
        if not self._report_progress:
            return
        if self._cumulative_num_processed % self._update_interval == 0:
            if self._time_for_refresh():
                assert(self._context_manager is not None)
                self._context_manager.update(
                    self._task, completed=self._cumulative_num_processed
                )
                self._context_manager.refresh()

    @property
    def num_processed(self):
        return self._cumulative_num_processed


cdef class FileReader:
    cdef cppstring _path

    cdef object _file
    cdef vector[_MemorySnapshot] _memory_snapshots
    cdef HighWatermark _high_watermark
    cdef object _header
    cdef bool _report_progress

    def __cinit__(self, object file_name, *, bool report_progress=False):
        try:
            self._file = open(file_name)
        except OSError as exc:
            raise OSError(f"Could not open file {file_name}: {exc.strerror}") from None

        self._path = "/proc/self/fd/" + str(self._file.fileno())
        self._report_progress = report_progress

        # Initial pass to populate _header, _high_watermark, and _memory_snapshots.
        cdef shared_ptr[RecordReader] reader_sp = make_shared[RecordReader](
            unique_ptr[FileSource](new FileSource(self._path)),
            False
        )
        cdef RecordReader* reader = reader_sp.get()

        self._header = reader.getHeader()
        stats = self._header["stats"]

        n_memory_snapshots_approx = 2048
        if 0 < stats["start_time"] < stats["end_time"]:
            n_memory_snapshots_approx = (stats["end_time"] - stats["start_time"]) / 10
        self._memory_snapshots.reserve(n_memory_snapshots_approx)

        cdef object total = stats['n_allocations'] or None
        cdef HighWatermarkFinder finder

        cdef ProgressIndicator progress_indicator = ProgressIndicator(
            "Calculating high watermark",
            total=total,
            report_progress=self._report_progress
        )
        cdef MemoryRecord memory_record
        with progress_indicator:
            while True:
                PyErr_CheckSignals()
                ret = reader.nextRecord()
                if ret == RecordResult.RecordResultAllocationRecord:
                    finder.processAllocation(reader.getLatestAllocation())
                    progress_indicator.update(1)
                elif ret == RecordResult.RecordResultMemoryRecord:
                    memory_record = reader.getLatestMemoryRecord()
                    self._memory_snapshots.push_back(
                        _MemorySnapshot(
                            memory_record.ms_since_epoch,
                            memory_record.rss,
                            finder.getCurrentWatermark(),
                        )
                    )
                else:
                    break
        self._high_watermark = finder.getHighWatermark()
        stats["n_allocations"] = progress_indicator.num_processed

    def __dealloc__(self):
        self.close()

    cpdef close(self):
        if self._file is not None:
            file = self._file
            self._file = None
            file.close()

    cdef void _ensure_not_closed(self) except *:
        if self._file is None:
            raise ValueError("Operation on a closed FileReader")

    @property
    def closed(self):
        return self._file is None

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, exc_traceback):
        self.close()

    def _aggregate_allocations(self, size_t records_to_process, bool merge_threads):
        cdef SnapshotAllocationAggregator aggregator
        cdef shared_ptr[RecordReader] reader_sp = make_shared[RecordReader](
            unique_ptr[FileSource](new FileSource(self._path))
        )
        cdef RecordReader* reader = reader_sp.get()

        cdef ProgressIndicator progress_indicator = ProgressIndicator(
            "Processing allocation records",
            total=records_to_process,
            report_progress=self._report_progress
        )

        with progress_indicator:
            while records_to_process > 0:
                PyErr_CheckSignals()
                ret = reader.nextRecord()
                if ret == RecordResult.RecordResultAllocationRecord:
                    aggregator.addAllocation(reader.getLatestAllocation())
                    records_to_process -= 1
                    progress_indicator.update(1)
                elif ret == RecordResult.RecordResultMemoryRecord:
                    pass
                else:
                    break

        for elem in Py_ListFromSnapshotAllocationRecords(
            aggregator.getSnapshotAllocations(merge_threads)
        ):
            alloc = AllocationRecord(elem)
            (<AllocationRecord> alloc)._reader = reader_sp
            yield alloc

        reader.close()

    def get_high_watermark_allocation_records(self, merge_threads=True):
        self._ensure_not_closed()
        # If allocation 0 caused the peak, we need to process 1 record, etc
        cdef size_t max_records = self._high_watermark.index + 1
        yield from self._aggregate_allocations(max_records, merge_threads)

    def get_leaked_allocation_records(self, merge_threads=True):
        self._ensure_not_closed()
        cdef size_t max_records = self._header["stats"]["n_allocations"]
        yield from self._aggregate_allocations(max_records, merge_threads)

    def get_allocation_records(self):
        self._ensure_not_closed()
        cdef shared_ptr[RecordReader] reader_sp = make_shared[RecordReader](
            unique_ptr[FileSource](new FileSource(self._path))
        )
        cdef RecordReader* reader = reader_sp.get()

        while True:
            PyErr_CheckSignals()
            ret = reader.nextRecord()
            if ret == RecordResult.RecordResultAllocationRecord:
                alloc = AllocationRecord(reader.getLatestAllocation().toPythonObject())
                (<AllocationRecord> alloc)._reader = reader_sp
                yield alloc
            elif ret == RecordResult.RecordResultMemoryRecord:
                pass
            else:
                break

        reader.close()

    def get_memory_snapshots(self):
        for record in self._memory_snapshots:
            yield MemorySnapshot(record.ms_since_epoch, record.rss, record.heap)

    @property
    def metadata(self):
        return _create_metadata(self._header, self._high_watermark.peak_memory)


def compute_statistics(
    file_name,
    *,
    report_progress=False,
    num_largest=5,
):
    cdef shared_ptr[RecordReader] reader_sp = make_shared[RecordReader](
        unique_ptr[FileSource](new FileSource(file_name))
    )
    cdef RecordReader* reader = reader_sp.get()

    cdef header = reader.getHeader()
    total = header["stats"]["n_allocations"] or None

    cdef AllocationStatsAggregator aggregator
    cdef ProgressIndicator progress_indicator = ProgressIndicator(
        "Computing statistics",
        total=total,
        report_progress=report_progress,
    )
    with progress_indicator:
        while True:
            PyErr_CheckSignals()
            ret = reader.nextRecord()
            if ret == RecordResult.RecordResultAllocationRecord:
                aggregator.addAllocation(
                    reader.getLatestAllocation(),
                    reader.getLatestPythonFrameId(reader.getLatestAllocation()),
                )
                progress_indicator.update(1)
            elif ret == RecordResult.RecordResultMemoryRecord:
                pass
            else:
                break

    # Ignore the n_allocations in the header, use our observed value.
    header["stats"]["n_allocations"] = progress_indicator.num_processed

    # Convert allocation counts by allocator/by size to Python dicts.
    cdef dict tmp = aggregator.allocationCountByAllocator()
    allocation_count_by_allocator = {AllocatorType(k).name: v for k, v in tmp.items()}
    cdef dict allocation_count_by_size = aggregator.allocationCountBySize();

    # Convert top locations by bytes allocated/by allocation count to dicts
    unknown = ("<unknown>", "<unknown>", 0)

    top_locations_by_size = [
        ((reader.Py_GetFrame(size_and_loc.second) or unknown), size_and_loc.first)
        for size_and_loc in aggregator.topLocationsBySize(num_largest)
    ]

    top_locations_by_count = [
        ((reader.Py_GetFrame(count_and_loc.second) or unknown), count_and_loc.first)
        for count_and_loc in aggregator.topLocationsByCount(num_largest)
    ]

    # And we're done!
    cdef uint64_t peak_memory = aggregator.peakBytesAllocated()
    return Stats(
        metadata=_create_metadata(header, peak_memory),
        total_num_allocations=aggregator.totalAllocations(),
        total_memory_allocated=aggregator.totalBytesAllocated(),
        peak_memory_allocated=peak_memory,
        allocation_count_by_size=allocation_count_by_size,
        allocation_count_by_allocator=allocation_count_by_allocator,
        top_locations_by_size=top_locations_by_size,
        top_locations_by_count=top_locations_by_count,
    )


def dump_all_records(object file_name):
    cdef str path = str(file_name)
    if not pathlib.Path(path).exists():
        raise IOError(f"No such file: {path}")

    cdef shared_ptr[RecordReader] _reader = make_shared[RecordReader](
            unique_ptr[FileSource](new FileSource(path)))
    _reader.get().dumpAllRecords()


cdef class SocketReader:
    cdef BackgroundSocketReader* _impl
    cdef shared_ptr[RecordReader] _reader
    cdef object _header
    cdef object _port

    def __cinit__(self, int port):
        self._impl = NULL

    def __init__(self, port: int):
        self._header = {}
        self._port = port

    cdef _teardown(self):
        with nogil:
            del self._impl
        self._impl = NULL

    cdef unique_ptr[SocketSource] _make_source(self) except*:
        # Creating a SocketSource can raise Python exceptions (if is interrupted by signal
        # handlers). If this happens, this method will propagate the appropriate exception.
        # We cannot use make_unique or C++ exceptions from SocketSource() won't be caught.
        cdef SocketSource* source = new SocketSource(self._port)
        return unique_ptr[SocketSource](source)

    def __enter__(self):
        if self._impl is not NULL:
            raise ValueError(
                "Can not enter the context of a SocketReader object more than "
                "once, at the same time."
            )

        self._reader = make_shared[RecordReader](move(self._make_source()))
        self._header = self._reader.get().getHeader()

        self._impl = new BackgroundSocketReader(self._reader)
        self._impl.start()

        return self

    def __exit__(self, exc_type, exc_value, exc_traceback):
        assert self._impl is not NULL

        self._teardown()
        self._reader.get().close()

    def __dealloc__(self):
        if self._impl is not NULL:
            self._teardown()

    @property
    def command_line(self):
        if not self._header:
            return None
        return self._header["command_line"]

    @property
    def is_active(self):
        if self._impl == NULL:
            return False
        return self._impl.is_active()

    @property
    def pid(self):
        if not self._header:
            return None
        return self._header["pid"]

    @property
    def has_native_traces(self):
        if not self._header:
            return False
        return self._header["native_traces"]

    def get_current_snapshot(self, *, bool merge_threads):
        if self._impl is NULL:
            return

        snapshot_allocations = self._impl.Py_GetSnapshotAllocationRecords(merge_threads=merge_threads)
        for elem in snapshot_allocations:
            alloc = AllocationRecord(elem)
            (<AllocationRecord> alloc)._reader = self._reader
            yield alloc
