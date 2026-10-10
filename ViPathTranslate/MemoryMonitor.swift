import Foundation
import Darwin
import os

/// Đo RAM thật của app (phys_footprint — đúng con số iOS dùng để quyết định đóng app)
/// và RAM còn được cấp thêm (os_proc_available_memory). Ghi lại mức cao nhất theo từng tab.
@MainActor
@Observable
final class MemoryMonitor {
    static let shared = MemoryMonitor()

    private(set) var footprint: UInt64 = 0
    private(set) var available: UInt64 = 0
    /// Mức RAM cao nhất đo được khi đang ở mỗi tab (kể từ lần đặt lại).
    private(set) var peakByTab: [AppTab: UInt64] = [:]
    private(set) var warningCount = 0
    private(set) var lastWarning: Date?
    private(set) var lastWarningAction: String?

    /// Tổng giới hạn iOS đang cấp cho app ≈ đang dùng + còn trống.
    var limit: UInt64 { footprint + available }

    /// Tuỳ chọn: đóng Whisper khi rời Đại thể / Phụ đề / Chép lời (mặc định tắt — tránh phải nạp lại).
    var releaseOnTabLeave: Bool = UserDefaults.standard.bool(forKey: "releaseSpeechOnTabLeave") {
        didSet { UserDefaults.standard.set(releaseOnTabLeave, forKey: "releaseSpeechOnTabLeave") }
    }

    private var currentTab: AppTab = .translate
    private var sampler: Task<Void, Never>?

    private init() {
        sample()
        sampler = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.sample()
            }
        }
    }

    func tabChanged(to tab: AppTab) {
        currentTab = tab
        sample()
    }

    func sample() {
        footprint = Self.currentFootprint()
        available = UInt64(os_proc_available_memory())
        if footprint > peakByTab[currentTab] ?? 0 { peakByTab[currentTab] = footprint }
    }

    func resetPeaks() {
        peakByTab = [:]
        warningCount = 0
        lastWarning = nil
        lastWarningAction = nil
        sample()
    }

    func recordWarning(action: String?) {
        warningCount += 1
        lastWarning = Date()
        lastWarningAction = action
        sample()
    }

    nonisolated static func currentFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let task = task_self_trap()
        defer { mach_port_deallocate(task, task) }
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(task, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    static func gb(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }
}
