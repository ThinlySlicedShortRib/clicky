//
//  StuckProcessProbe.swift
//  leanring-buddy
//
//  Asks the kernel what this process is doing, so the receipt shows measured
//  numbers rather than a promise. scripts/prove-privacy.sh checks the same
//  counters from outside the process with lsof and proc_pid_rusage.
//

import Darwin
import Foundation

enum StuckProcessProbe {
    struct NetworkSocketCount {
        let internetSockets: Int
        let unixDomainSockets: Int
    }

    /// Counts this process's open sockets by family.
    static func openSocketCount() -> NetworkSocketCount {
        let processIdentifier = getpid()
        let bufferSizeInBytes = proc_pidinfo(processIdentifier, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSizeInBytes > 0 else {
            return NetworkSocketCount(internetSockets: 0, unixDomainSockets: 0)
        }

        let fileDescriptorCapacity = Int(bufferSizeInBytes) / MemoryLayout<proc_fdinfo>.stride
        var fileDescriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: fileDescriptorCapacity)
        let bytesReturned = proc_pidinfo(processIdentifier, PROC_PIDLISTFDS, 0, &fileDescriptors, bufferSizeInBytes)
        let fileDescriptorCount = Int(bytesReturned) / MemoryLayout<proc_fdinfo>.stride

        var internetSockets = 0
        var unixDomainSockets = 0

        for fileDescriptor in fileDescriptors.prefix(fileDescriptorCount)
        where fileDescriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socketInformation = socket_fdinfo()
            let socketInformationSize = Int32(MemoryLayout<socket_fdinfo>.size)
            let bytesRead = proc_pidfdinfo(
                processIdentifier,
                fileDescriptor.proc_fd,
                PROC_PIDFDSOCKETINFO,
                &socketInformation,
                socketInformationSize
            )
            guard bytesRead == socketInformationSize else { continue }

            switch socketInformation.psi.soi_family {
            case AF_INET, AF_INET6:
                internetSockets += 1
            case AF_UNIX:
                unixDomainSockets += 1
            default:
                break
            }
        }

        return NetworkSocketCount(internetSockets: internetSockets, unixDomainSockets: unixDomainSockets)
    }

    /// Bytes this process has written through the file system since launch,
    /// including buffered writes, which is why it's the logical figure rather
    /// than the physical disk one.
    static func logicalBytesWrittenSinceLaunch() -> UInt64? {
        var resourceUsage = rusage_info_v4()
        let resultCode = withUnsafeMutablePointer(to: &resourceUsage) { resourceUsagePointer in
            resourceUsagePointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPointer in
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, reboundPointer)
            }
        }
        return resultCode == 0 ? resourceUsage.ri_logical_writes : nil
    }
}
