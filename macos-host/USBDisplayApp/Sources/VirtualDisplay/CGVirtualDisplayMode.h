// CGVirtualDisplayMode.h - Private API header (class-dumped)
#import <Foundation/Foundation.h>

@interface CGVirtualDisplayMode : NSObject

@property(readonly, nonatomic) unsigned int width;
@property(readonly, nonatomic) unsigned int height;
@property(readonly, nonatomic) double refreshRate;

- (id)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;

@end
