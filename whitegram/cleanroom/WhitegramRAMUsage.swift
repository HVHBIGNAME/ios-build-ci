import Darwin
import Foundation

public enum WhitegramRAMUsage {
    public static func physicalFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { words in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), words, &count)
            }
        }
        // phys_footprint ends at word 38 of TASK_VM_INFO (the original REV1 guard).
        guard result == KERN_SUCCESS, count >= 38 else { return nil }
        return info.phys_footprint
    }

    static func text(physicalFootprint: UInt64) -> String {
        return "\(physicalFootprint >> 20) MB"
    }

    static func frame(labelSize: CGSize, statusBarHeight: CGFloat, leftInset: CGFloat, scale: CGFloat) -> CGRect {
        let size = CGSize(width: ceil(labelSize.width), height: ceil(labelSize.height))
        let x = floor(max(6.0, leftInset + 6.0) * scale) / scale
        let y = floor(max(12.0, statusBarHeight - size.height - 1.0) * scale) / scale
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}
