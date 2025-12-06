// VirtualDisplayManager.h - Wrapper for CGVirtualDisplay private API
#ifndef VirtualDisplayManager_h
#define VirtualDisplayManager_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface VirtualDisplayManager : NSObject

/// Create a virtual display with the specified parameters
/// @param width Display width in pixels
/// @param height Display height in pixels
/// @param ppi Pixels per inch (e.g., 110 for standard, 220 for Retina)
/// @param hiDPI Whether to enable HiDPI/Retina mode
/// @param name Display name shown in System Preferences
/// @return YES if display was created successfully
- (BOOL)createDisplayWithWidth:(int)width
                        height:(int)height
                           ppi:(int)ppi
                         hiDPI:(BOOL)hiDPI
                          name:(NSString *)name;

/// Get the CGDisplayID of the virtual display (0 if not created)
@property (readonly) CGDirectDisplayID displayID;

/// Whether a virtual display is currently active
@property (readonly) BOOL isActive;

/// Destroy the virtual display
- (void)destroyDisplay;

@end

NS_ASSUME_NONNULL_END

#endif /* VirtualDisplayManager_h */
