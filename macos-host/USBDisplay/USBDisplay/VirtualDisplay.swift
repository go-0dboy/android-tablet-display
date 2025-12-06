// VirtualDisplay.swift - Virtual display creation using private CGVirtualDisplay APIs
import Foundation
import CoreGraphics

/// Manager for creating and managing virtual displays using private macOS APIs
class VirtualDisplayManager {
    private var virtualDisplay: AnyObject?
    private(set) var displayID: CGDirectDisplayID = 0

    var isActive: Bool { virtualDisplay != nil }

    /// Create a virtual display with the specified parameters
    /// - Parameters:
    ///   - width: Display width in pixels
    ///   - height: Display height in pixels
    ///   - ppi: Pixels per inch (e.g., 110 for standard, 220 for Retina)
    ///   - hiDPI: Whether to enable HiDPI/Retina mode
    ///   - name: Display name shown in System Preferences
    /// - Returns: true if display was created successfully
    func createDisplay(width: Int, height: Int, ppi: Int, hiDPI: Bool, name: String) -> Bool {
        // Destroy existing display first
        destroyDisplay()

        // Get private classes via runtime
        guard let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let displayClass = NSClassFromString("CGVirtualDisplay") as? NSObject.Type,
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
              let modeClass = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type else {
            log("VirtualDisplayManager: CGVirtualDisplay API not available")
            return false
        }

        // Create descriptor
        let descriptor = descriptorClass.init()

        // Set properties via KVC
        descriptor.setValue(name, forKey: "name")
        descriptor.setValue(DispatchQueue.main, forKey: "queue")

        // Calculate physical size from resolution and PPI
        let widthMM = Double(width) / Double(ppi) * 25.4
        let heightMM = Double(height) / Double(ppi) * 25.4
        descriptor.setValue(NSValue(cgSize: CGSize(width: widthMM, height: heightMM)), forKey: "sizeInMillimeters")

        // Set max resolution
        descriptor.setValue(width, forKey: "maxPixelsWide")
        descriptor.setValue(height, forKey: "maxPixelsHigh")

        // Set hardware identifiers
        descriptor.setValue(0x1234, forKey: "vendorID")
        descriptor.setValue(0x5678, forKey: "productID")
        descriptor.setValue(0x0001, forKey: "serialNum")

        // Set color primaries (sRGB values)
        descriptor.setValue(NSValue(cgPoint: CGPoint(x: 0.64, y: 0.33)), forKey: "redPrimary")
        descriptor.setValue(NSValue(cgPoint: CGPoint(x: 0.30, y: 0.60)), forKey: "greenPrimary")
        descriptor.setValue(NSValue(cgPoint: CGPoint(x: 0.15, y: 0.06)), forKey: "bluePrimary")
        descriptor.setValue(NSValue(cgPoint: CGPoint(x: 0.3127, y: 0.3290)), forKey: "whitePoint")

        // Create the virtual display using initWithDescriptor:
        let initSelector = NSSelectorFromString("initWithDescriptor:")
        guard displayClass.instancesRespond(to: initSelector) else {
            log("VirtualDisplayManager: initWithDescriptor: not available")
            return false
        }

        let display = displayClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject
        guard let display = display else {
            log("VirtualDisplayManager: Failed to allocate display")
            return false
        }

        // Call initWithDescriptor:
        let initMethod = display.perform(initSelector, with: descriptor)
        guard initMethod != nil else {
            log("VirtualDisplayManager: initWithDescriptor: returned nil")
            return false
        }

        // Create settings
        let settings = settingsClass.init()
        settings.setValue(hiDPI ? 1 : 0, forKey: "hiDPI")

        // Create display mode - for HiDPI, mode resolution is half the pixel resolution
        let modeWidth = hiDPI ? width / 2 : width
        let modeHeight = hiDPI ? height / 2 : height

        let modeInitSelector = NSSelectorFromString("initWithWidth:height:refreshRate:")
        guard modeClass.instancesRespond(to: modeInitSelector) else {
            log("VirtualDisplayManager: CGVirtualDisplayMode init not available")
            return false
        }

        // Create mode via NSInvocation since we need to pass primitives
        let mode = createDisplayMode(modeClass: modeClass, width: modeWidth, height: modeHeight, refreshRate: 60.0)
        guard let mode = mode else {
            log("VirtualDisplayManager: Failed to create display mode")
            return false
        }

        settings.setValue([mode], forKey: "modes")

        // Apply settings
        let applySelector = NSSelectorFromString("applySettings:")
        guard display.responds(to: applySelector) else {
            log("VirtualDisplayManager: applySettings: not available")
            return false
        }

        let result = display.perform(applySelector, with: settings)
        // Check if it returned true (non-nil for BOOL return)
        if result == nil {
            log("VirtualDisplayManager: applySettings: returned nil/false")
            return false
        }

        // Get display ID
        if let dispID = display.value(forKey: "displayID") as? UInt32 {
            self.displayID = dispID
        }

        self.virtualDisplay = display
        log("VirtualDisplayManager: Created virtual display '\(name)' (\(width)x\(height) @ \(ppi) ppi, hiDPI=\(hiDPI)) with displayID=\(displayID)")

        return true
    }

    private func createDisplayMode(modeClass: NSObject.Type, width: Int, height: Int, refreshRate: Double) -> NSObject? {
        // Use method signature approach for init with primitives
        let mode = modeClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject
        guard let mode = mode else { return nil }

        // Try to initialize - CGVirtualDisplayMode initWithWidth:height:refreshRate:
        let selector = NSSelectorFromString("initWithWidth:height:refreshRate:")

        guard mode.responds(to: selector) else { return nil }

        // We need to use NSInvocation or a different approach for primitive parameters
        // Let's try using objc_msgSend directly via perform
        typealias InitMethod = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> AnyObject?

        let method: InitMethod = unsafeBitCast(
            class_getMethodImplementation(type(of: mode), selector),
            to: InitMethod.self
        )

        let result = method(mode, selector, UInt32(width), UInt32(height), refreshRate)
        return result as? NSObject
    }

    /// Destroy the virtual display
    func destroyDisplay() {
        if virtualDisplay != nil {
            log("VirtualDisplayManager: Destroying virtual display with ID=\(displayID)")
            virtualDisplay = nil
            displayID = 0
        }
    }

    deinit {
        destroyDisplay()
    }
}
