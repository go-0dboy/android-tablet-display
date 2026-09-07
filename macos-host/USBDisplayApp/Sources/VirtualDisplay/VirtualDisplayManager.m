#import "VirtualDisplayManager.h"
#import "CGVirtualDisplay.h"
#import "CGVirtualDisplayDescriptor.h"
#import "CGVirtualDisplaySettings.h"
#import "CGVirtualDisplayMode.h"

@implementation VirtualDisplayParameters

+ (instancetype)specWithPixelWidth:(int)pixelWidth
                       pixelHeight:(int)pixelHeight
                        pointWidth:(int)pointWidth
                       pointHeight:(int)pointHeight
                               ppi:(int)ppi
                             hiDPI:(BOOL)hiDPI
                       refreshRate:(double)refreshRate
                              name:(NSString *)name {
    VirtualDisplayParameters *spec = [[VirtualDisplayParameters alloc] init];
    spec.pixelWidth = pixelWidth;
    spec.pixelHeight = pixelHeight;
    spec.pointWidth = pointWidth > 0 ? pointWidth : pixelWidth;
    spec.pointHeight = pointHeight > 0 ? pointHeight : pixelHeight;
    spec.ppi = ppi > 0 ? ppi : 110;
    spec.hiDPI = hiDPI;
    spec.refreshRate = refreshRate > 0 ? refreshRate : 60.0;
    spec.name = name.length ? [name copy] : @"Android Tablet Display";
    // Fixed synthetic EDID identifiers. Deliberately constant and unrelated to
    // any real hardware serial.
    spec.vendorID = 0x1234;
    spec.productID = 0x5678;
    spec.serialNum = 0x0001;
    return spec;
}

@end


@interface VirtualDisplayManager ()
@property (strong, nullable) CGVirtualDisplay *virtualDisplay;
@property (nullable, copy) NSString *lastError;
@end

@implementation VirtualDisplayManager

+ (NSArray<NSString *> *)missingPrivateClasses {
    NSArray<NSString *> *required = @[ @"CGVirtualDisplay",
                                       @"CGVirtualDisplayDescriptor",
                                       @"CGVirtualDisplaySettings",
                                       @"CGVirtualDisplayMode" ];
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    for (NSString *name in required) {
        if (NSClassFromString(name) == nil) { [missing addObject:name]; }
    }
    return missing;
}

+ (BOOL)privateAPIAvailable {
    return [self missingPrivateClasses].count == 0;
}

- (BOOL)createDisplayWithWidth:(int)width
                        height:(int)height
                           ppi:(int)ppi
                         hiDPI:(BOOL)hiDPI
                          name:(NSString *)name {
    VirtualDisplayParameters *spec =
        [VirtualDisplayParameters specWithPixelWidth:width
                                   pixelHeight:height
                                    pointWidth:(hiDPI ? width / 2 : width)
                                   pointHeight:(hiDPI ? height / 2 : height)
                                           ppi:ppi
                                         hiDPI:hiDPI
                                   refreshRate:60.0
                                          name:name];
    return [self createDisplayWithSpec:spec];
}

- (BOOL)createDisplayWithSpec:(VirtualDisplayParameters *)spec {
    self.lastError = nil;

    if (![VirtualDisplayManager privateAPIAvailable]) {
        NSArray *missing = [VirtualDisplayManager missingPrivateClasses];
        self.lastError = [NSString stringWithFormat:
            @"This macOS release does not expose the private virtual-display API "
            @"(missing: %@). Virtual display cannot be created.",
            [missing componentsJoinedByString:@", "]];
        NSLog(@"VirtualDisplayManager: %@", self.lastError);
        return NO;
    }

    [self destroyDisplay];

    CGVirtualDisplayDescriptor *descriptor = [[CGVirtualDisplayDescriptor alloc] init];
    descriptor.name = spec.name;
    [descriptor setDispatchQueue:dispatch_get_main_queue()];

    // Physical size drives macOS's own density calculation, so derive it from
    // the client's real dpi rather than a constant.
    float widthMM = (float)spec.pixelWidth / (float)spec.ppi * 25.4f;
    float heightMM = (float)spec.pixelHeight / (float)spec.ppi * 25.4f;
    descriptor.sizeInMillimeters = CGSizeMake(widthMM, heightMM);

    descriptor.maxPixelsWide = (unsigned int)spec.pixelWidth;
    descriptor.maxPixelsHigh = (unsigned int)spec.pixelHeight;

    descriptor.vendorID = spec.vendorID;
    descriptor.productID = spec.productID;
    descriptor.serialNum = spec.serialNum;

    // sRGB primaries with a D65 white point.
    descriptor.redPrimary   = CGPointMake(0.64, 0.33);
    descriptor.greenPrimary = CGPointMake(0.30, 0.60);
    descriptor.bluePrimary  = CGPointMake(0.15, 0.06);
    descriptor.whitePoint   = CGPointMake(0.3127, 0.3290);

    // macOS can tear the display down on its own — notably across some
    // sleep/wake cycles. Without this handler the app keeps streaming to a
    // display ID that no longer exists.
    __weak typeof(self) weakSelf = self;
    descriptor.terminationHandler = ^(id sender, id context) {
        NSLog(@"VirtualDisplayManager: display terminated by the system");
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) { return; }
            strongSelf.virtualDisplay = nil;
            if (strongSelf.onTerminated) { strongSelf.onTerminated(); }
        });
    };

    // WindowServer keys a display's saved arrangement to its
    // vendor/product/serial, so the identity has to stay stable across
    // restarts -- but it also refuses to create a second display with an
    // identity that is already in use. Both are true at once, so: try the
    // stable identity first, and only walk the serial forward if it is taken.
    CGVirtualDisplay *display = nil;
    unsigned int serial = spec.serialNum;
    for (int attempt = 0; attempt < 8; attempt++) {
        descriptor.serialNum = serial;
        display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
        if (display) {
            if (attempt > 0) {
                NSLog(@"VirtualDisplayManager: identity %u was taken; using serial %u",
                      spec.serialNum, serial);
            }
            break;
        }
        serial++;
    }

    if (!display) {
        self.lastError = @"CGVirtualDisplay initWithDescriptor: returned nil for every "
                         @"identity tried. The private API is present but refused to "
                         @"create a display. Another app may be holding several "
                         @"virtual displays, or macOS has saved a broken configuration "
                         @"for this identity -- see docs/STATUS.md.";
        NSLog(@"VirtualDisplayManager: %@", self.lastError);
        return NO;
    }
    self.virtualDisplay = display;

    if (![self applyModeWithSpec:spec]) {
        self.virtualDisplay = nil;
        return NO;
    }

    // WindowServer picks its own mode from the ladder and does not always pick
    // the one we asked for, so assert it explicitly once the display settles.
    [self enforceModeForSpec:spec];

    NSLog(@"VirtualDisplayManager: created '%@' %dx%d px / %dx%d pt @ %d ppi "
          @"(hiDPI=%d, %.0fHz) displayID=%u",
          spec.name, spec.pixelWidth, spec.pixelHeight,
          spec.pointWidth, spec.pointHeight, spec.ppi,
          spec.hiDPI, spec.refreshRate, display.displayID);
    return YES;
}

- (BOOL)applyModeWithSpec:(VirtualDisplayParameters *)spec {
    if (!self.virtualDisplay) {
        self.lastError = @"No virtual display to apply a mode to.";
        return NO;
    }

    CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
    settings.hiDPI = spec.hiDPI ? 1 : 0;

    // The HiDPI ladder has to be declared as a pair. Declaring only the
    // point-size mode means macOS never enumerates the @2x variant and the
    // display comes up at 1x on a high-density panel; declaring only the
    // pixel-size mode means there is no scaled mode to select at all.
    NSMutableArray<CGVirtualDisplayMode *> *modes = [NSMutableArray array];

    CGVirtualDisplayMode *pointMode =
        [[CGVirtualDisplayMode alloc] initWithWidth:(unsigned int)spec.pointWidth
                                             height:(unsigned int)spec.pointHeight
                                        refreshRate:spec.refreshRate];
    if (!pointMode) {
        self.lastError = @"CGVirtualDisplayMode could not be created.";
        NSLog(@"VirtualDisplayManager: %@", self.lastError);
        return NO;
    }
    [modes addObject:pointMode];

    if (spec.hiDPI && (spec.pixelWidth != spec.pointWidth || spec.pixelHeight != spec.pointHeight)) {
        CGVirtualDisplayMode *nativeMode =
            [[CGVirtualDisplayMode alloc] initWithWidth:(unsigned int)spec.pixelWidth
                                                 height:(unsigned int)spec.pixelHeight
                                            refreshRate:spec.refreshRate];
        if (nativeMode) { [modes addObject:nativeMode]; }
    }

    settings.modes = modes;

    if (![self.virtualDisplay applySettings:settings]) {
        self.lastError = [NSString stringWithFormat:
            @"applySettings: refused %dx%d @ %.0fHz (hiDPI=%d).",
            spec.pointWidth, spec.pointHeight, spec.refreshRate, spec.hiDPI];
        NSLog(@"VirtualDisplayManager: %@", self.lastError);
        return NO;
    }
    return YES;
}

/// macOS is free to substitute its own scaled mode after a display appears —
/// a 2560x1600 panel routinely comes up "looks like 1280x800" on its own. Walk
/// the mode list and select the one matching the spec if it is there.
- (void)enforceModeForSpec:(VirtualDisplayParameters *)spec {
    CGDirectDisplayID display = self.displayID;
    if (display == 0) { return; }

    // Give WindowServer a moment to publish the mode list.
    [NSThread sleepForTimeInterval:0.3];

    // Without kCGDisplayShowDuplicateLowResolutionModes the returned list
    // omits every HiDPI mode, so a search for the 2x mode finds nothing and
    // the display silently stays at 1x. This one option is the difference
    // between a crisp tablet and a blurry one.
    const void *keys[] = { kCGDisplayShowDuplicateLowResolutionModes };
    const void *values[] = { kCFBooleanTrue };
    CFDictionaryRef options = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
                                                 &kCFTypeDictionaryKeyCallBacks,
                                                 &kCFTypeDictionaryValueCallBacks);
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(display, options);
    if (options) { CFRelease(options); }
    if (!modes) { return; }

    CGDisplayModeRef best = NULL;
    for (CFIndex i = 0; i < CFArrayGetCount(modes); i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        size_t pixelWidth = CGDisplayModeGetPixelWidth(mode);
        size_t pixelHeight = CGDisplayModeGetPixelHeight(mode);
        size_t pointWidth = CGDisplayModeGetWidth(mode);
        size_t pointHeight = CGDisplayModeGetHeight(mode);

        if ((int)pixelWidth == spec.pixelWidth && (int)pixelHeight == spec.pixelHeight &&
            (int)pointWidth == spec.pointWidth && (int)pointHeight == spec.pointHeight) {
            best = mode;
            break;
        }
    }

    if (best) {
        CGDisplayConfigRef config;
        if (CGBeginDisplayConfiguration(&config) == kCGErrorSuccess) {
            CGConfigureDisplayWithDisplayMode(config, display, best, NULL);
            CGCompleteDisplayConfiguration(config, kCGConfigurePermanently);
            NSLog(@"VirtualDisplayManager: asserted mode %dx%d px / %dx%d pt",
                  spec.pixelWidth, spec.pixelHeight, spec.pointWidth, spec.pointHeight);
        }
    } else {
        NSLog(@"VirtualDisplayManager: requested mode %dx%d pt was not offered; "
              @"macOS kept its own choice", spec.pointWidth, spec.pointHeight);
    }
    CFRelease(modes);
}

- (CGDirectDisplayID)displayID {
    return self.virtualDisplay ? self.virtualDisplay.displayID : 0;
}

- (BOOL)isActive {
    // A display the system terminated leaves displayID reporting 0.
    return self.virtualDisplay != nil && self.virtualDisplay.displayID != 0;
}

- (void)destroyDisplay {
    if (!self.virtualDisplay) { return; }

    CGDirectDisplayID going = self.virtualDisplay.displayID;
    NSLog(@"VirtualDisplayManager: destroying display %u", going);
    self.virtualDisplay = nil;

    // Teardown is asynchronous inside WindowServer. Recreating a display
    // before the old one has gone makes the next applySettings: fail, so wait
    // for it to leave the active list — bounded, because at least one report
    // says the display only truly goes when the owning process exits.
    if (going == 0) { return; }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
    while ([deadline timeIntervalSinceNow] > 0) {
        uint32_t count = 0;
        CGDirectDisplayID ids[32];
        if (CGGetActiveDisplayList(32, ids, &count) != kCGErrorSuccess) { break; }
        BOOL stillThere = NO;
        for (uint32_t i = 0; i < count; i++) {
            if (ids[i] == going) { stillThere = YES; break; }
        }
        if (!stillThere) { return; }
        [NSThread sleepForTimeInterval:0.1];
    }
    NSLog(@"VirtualDisplayManager: display %u still listed after teardown wait", going);
}

- (void)dealloc {
    [self destroyDisplay];
}

@end
