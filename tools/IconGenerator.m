#import <Cocoa/Cocoa.h>
int main(int argc,char **argv) { @autoreleasepool {
    NSString *folder=@(argv[1]);
    NSArray *sizes=@[@16,@32,@64,@128,@256,@512,@1024];
    for(NSNumber *number in sizes) {
        int size=number.intValue;
        NSBitmapImageRep *rep=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:size pixelsHigh:size bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        [NSGraphicsContext saveGraphicsState]; [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
        NSAffineTransform *transform=[NSAffineTransform transform]; [transform scaleBy:size/1024.0]; [transform concat];
        [[NSColor colorWithRed:0.07 green:0.12 blue:0.22 alpha:1] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(65,65,894,894) xRadius:190 yRadius:190] fill];
        NSBezierPath *hinge=[NSBezierPath bezierPath]; hinge.lineWidth=54; hinge.lineCapStyle=NSLineCapStyleRound;
        [hinge moveToPoint:NSMakePoint(310,735)]; [hinge lineToPoint:NSMakePoint(410,300)]; [hinge lineToPoint:NSMakePoint(790,300)];
        [[NSColor colorWithRed:0.35 green:0.81 blue:1 alpha:1] setStroke]; [hinge stroke];
        NSBezierPath *arc=[NSBezierPath bezierPath]; arc.lineWidth=22;
        [arc appendBezierPathWithArcWithCenter:NSMakePoint(410,300) radius:175 startAngle:0 endAngle:103];
        [[NSColor colorWithRed:0.98 green:0.66 blue:0.24 alpha:1] setStroke]; [arc stroke];
        [@"°" drawAtPoint:NSMakePoint(655,560) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:235 weight:NSFontWeightMedium],NSForegroundColorAttributeName:NSColor.whiteColor}];
        [NSGraphicsContext restoreGraphicsState];
        NSData *png=[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if(size<=512) [png writeToFile:[folder stringByAppendingPathComponent:[NSString stringWithFormat:@"icon_%dx%d.png",size,size]] atomically:YES];
        if(size>=32) [png writeToFile:[folder stringByAppendingPathComponent:[NSString stringWithFormat:@"icon_%dx%d@2x.png",size/2,size/2]] atomically:YES];
    }
} return 0; }
