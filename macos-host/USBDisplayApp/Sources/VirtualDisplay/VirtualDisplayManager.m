// VirtualDisplayManager.m - Wrapper for CGVirtualDisplay private API
#import "VirtualDisplayManager.h"
#import "CGVirtualDisplay.h"
#import "CGVirtualDisplayDescriptor.h"
#import "CGVirtualDisplaySettings.h"
#import "CGVirtualDisplayMode.h"

@interface VirtualDisplayManager ()
@property (strong) CGVirtualDisplay *virtualDisplay;
@end

@implementation VirtualDisplayManager

- (instancetype)init {
    self = [super init];
    if (self) {
        _virtualDisplay = nil;
    }
    return self;
}

- (BOOL)createDisplayWithWidth:(int)width
                        height:(int)height
                           ppi:(int)ppi
                         hiDPI:(BOOL)hiDPI
                          name:(NSString *)name {
    // Destroy existing display first
    [self destroyDisplay];

    // Create descriptor
    CGVirtualDisplayDescriptor *descriptor = [[CGVirtualDisplayDescriptor alloc] init];

    // Set display name
    descriptor.name = name;

    // Set dispatch queue
    [descriptor setDispatchQueue:dispatch_get_main_queue()];

    // Calculate physical size from resolution and PPI
    // size in mm = (pixels / ppi) * 25.4
    float widthMM = (float)width / ppi * 25.4f;
    float heightMM = (float)height / ppi * 25.4f;
    descriptor.sizeInMillimeters = CGSizeMake(widthMM, heightMM);

    // Set max resolution
    descriptor.maxPixelsWide = width;
    descriptor.maxPixelsHigh = height;

    // Set hardware identifiers (arbitrary values)
    descriptor.vendorID = 0x1234;    // Custom vendor ID
    descriptor.productID = 0x5678;   // Custom product ID
    descriptor.serialNum = 0x0001;   // Serial number

    // Set color primaries (sRGB-ish values)
    descriptor.redPrimary = CGPointMake(0.64, 0.33);
    descriptor.greenPrimary = CGPointMake(0.30, 0.60);
    descriptor.bluePrimary = CGPointMake(0.15, 0.06);
    descriptor.whitePoint = CGPointMake(0.3127, 0.3290);  // D65

    // Create the virtual display
    self.virtualDisplay = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];

    if (!self.virtualDisplay) {
        NSLog(@"VirtualDisplayManager: Failed to create virtual display");
        return NO;
    }

    // Create settings with display mode
    CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
    settings.hiDPI = hiDPI ? 1 : 0;

    // For HiDPI, the mode resolution is half the pixel resolution
    int modeWidth = hiDPI ? width / 2 : width;
    int modeHeight = hiDPI ? height / 2 : height;

    CGVirtualDisplayMode *mode = [[CGVirtualDisplayMode alloc] initWithWidth:modeWidth
                                                                      height:modeHeight
                                                                 refreshRate:60.0];
    settings.modes = @[mode];

    // Apply settings
    if (![self.virtualDisplay applySettings:settings]) {
        NSLog(@"VirtualDisplayManager: Failed to apply display settings");
        self.virtualDisplay = nil;
        return NO;
    }

    NSLog(@"VirtualDisplayManager: Created virtual display '%@' (%dx%d @ %d ppi, hiDPI=%d) with displayID=%u",
          name, width, height, ppi, hiDPI, self.virtualDisplay.displayID);

    return YES;
}

- (CGDirectDisplayID)displayID {
    return self.virtualDisplay ? self.virtualDisplay.displayID : 0;
}

- (BOOL)isActive {
    return self.virtualDisplay != nil;
}

- (void)destroyDisplay {
    if (self.virtualDisplay) {
        NSLog(@"VirtualDisplayManager: Destroying virtual display with ID=%u", self.virtualDisplay.displayID);
        self.virtualDisplay = nil;
    }
}

- (void)dealloc {
    [self destroyDisplay];
}

@end
