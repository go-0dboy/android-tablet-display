// CGVirtualDisplay.h - Private API header (class-dumped)
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface CGVirtualDisplay : NSObject

@property(readonly, nonatomic) NSArray *modes;
@property(readonly, nonatomic) unsigned int hiDPI;
@property(readonly, nonatomic) unsigned int displayID;
@property(readonly, nonatomic) id terminationHandler;
@property(readonly, nonatomic) id queue;
@property(readonly, nonatomic) CGPoint whitePoint;
@property(readonly, nonatomic) CGPoint bluePrimary;
@property(readonly, nonatomic) CGPoint greenPrimary;
@property(readonly, nonatomic) CGPoint redPrimary;
@property(readonly, nonatomic) unsigned int maxPixelsHigh;
@property(readonly, nonatomic) unsigned int maxPixelsWide;
@property(readonly, nonatomic) CGSize sizeInMillimeters;
@property(readonly, nonatomic) NSString *name;
@property(readonly, nonatomic) unsigned int serialNum;
@property(readonly, nonatomic) unsigned int productID;
@property(readonly, nonatomic) unsigned int vendorID;

- (BOOL)applySettings:(id)settings;
- (id)initWithDescriptor:(id)descriptor;

@end
