// VirtualDisplayManager.h — Objective-C wrapper around the private
// CGVirtualDisplay CoreGraphics API.
//
// These classes are not public API. They exist in CoreGraphics.framework and
// are reached through class-dumped headers, which means Apple can change or
// remove them in any macOS release. Everything here is written to fail
// loudly rather than silently: -lastError carries the reason a create failed
// so the app can tell the user which step broke.
#ifndef VirtualDisplayManager_h
#define VirtualDisplayManager_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Everything needed to describe one virtual display.
@interface VirtualDisplayParameters : NSObject
/// Backing store, in pixels.
@property (nonatomic) int pixelWidth;
@property (nonatomic) int pixelHeight;
/// Desktop layout size, in points. Equals the pixel size unless hiDPI is set,
/// in which case it is normally half.
@property (nonatomic) int pointWidth;
@property (nonatomic) int pointHeight;
/// Physical density, used to derive the descriptor's size in millimetres.
@property (nonatomic) int ppi;
@property (nonatomic) BOOL hiDPI;
@property (nonatomic) double refreshRate;
/// Name shown in System Settings > Displays.
@property (nonatomic, copy) NSString *name;
/// EDID-ish identifiers. Defaults are arbitrary constants; they must not be
/// derived from any real device's serial number.
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int serialNum;

+ (instancetype)specWithPixelWidth:(int)pixelWidth
                       pixelHeight:(int)pixelHeight
                        pointWidth:(int)pointWidth
                       pointHeight:(int)pointHeight
                               ppi:(int)ppi
                             hiDPI:(BOOL)hiDPI
                       refreshRate:(double)refreshRate
                              name:(NSString *)name
    NS_SWIFT_NAME(make(pixelWidth:pixelHeight:pointWidth:pointHeight:ppi:hiDPI:refreshRate:name:));
@end


@interface VirtualDisplayManager : NSObject

/// YES if all four private classes resolve at runtime. NO means this macOS
/// release has moved or removed them and nothing else here can work.
+ (BOOL)privateAPIAvailable;

/// Which of the private classes are missing, for diagnostics. Empty when all
/// four are present.
+ (NSArray<NSString *> *)missingPrivateClasses;

/// Create (or replace) the virtual display.
- (BOOL)createDisplayWithSpec:(VirtualDisplayParameters *)spec NS_SWIFT_NAME(createDisplay(spec:));

/// Convenience for the simple case.
- (BOOL)createDisplayWithWidth:(int)width
                        height:(int)height
                           ppi:(int)ppi
                         hiDPI:(BOOL)hiDPI
                          name:(NSString *)name
    NS_SWIFT_NAME(createDisplay(width:height:ppi:hiDPI:name:));

/// Re-apply a mode to the display already created, without tearing it down.
/// Used when the client rotates or changes resolution.
- (BOOL)applyModeWithSpec:(VirtualDisplayParameters *)spec NS_SWIFT_NAME(applyMode(spec:));

/// CGDisplayID of the virtual display, 0 if not created.
@property (readonly) CGDirectDisplayID displayID;

/// Whether a virtual display is currently held.
@property (readonly) BOOL isActive;

/// Human-readable reason the last create/apply failed, or nil.
@property (readonly, nullable, copy) NSString *lastError;

/// Called on the main queue if macOS terminates the display underneath us —
/// which is what happens on some sleep/wake cycles.
@property (nonatomic, copy, nullable) void (^onTerminated)(void);

- (void)destroyDisplay;

@end

NS_ASSUME_NONNULL_END

#endif /* VirtualDisplayManager_h */
