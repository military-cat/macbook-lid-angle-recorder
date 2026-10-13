// Read-only MacBook hinge angle viewer. No device settings are written.
// Build the macOS app with ./build.sh from the source project.
#import <Cocoa/Cocoa.h>
#import <IOKit/hid/IOHIDManager.h>
#include <math.h>

static const double closeReferenceDegrees = 5.0;

static IOHIDManagerRef manager;
static IOHIDDeviceRef sensor;
static IOReturn lastError;
static BOOL fineResolution;

static BOOL connectSensor(void) {
    manager = IOHIDManagerCreate(kCFAllocatorDefault, 0);
    NSDictionary *match = @{@kIOHIDVendorIDKey:@1452,
                            @kIOHIDPrimaryUsagePageKey:@32,
                            @kIOHIDPrimaryUsageKey:@138};
    IOHIDManagerSetDeviceMatching(manager, (__bridge CFDictionaryRef)match);
    lastError = IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
    if (lastError != kIOReturnSuccess) return NO;
    CFSetRef devices = IOHIDManagerCopyDevices(manager);
    if (!devices) return NO;
    for (id item in (__bridge NSSet *)devices) {
        IOHIDDeviceRef candidate = (__bridge IOHIDDeviceRef)item;
        lastError = IOHIDDeviceOpen(candidate, kIOHIDOptionsTypeNone);
        if (lastError == kIOReturnSuccess) {
            sensor = (IOHIDDeviceRef)CFRetain(candidate);
            break;
        }
    }
    CFRelease(devices);
    return sensor != NULL;
}

static double readAngle(void) {
    if (!sensor) return NAN;
    // Report 7: little-endian uint32, hundredths of a degree.
    // Report 1: little-endian uint16, whole degrees.
    const int ids[] = {7, 1};
    for (int i = 0; i < 2; i++) {
        uint8_t bytes[64] = {0};
        bytes[0] = ids[i];
        CFIndex length = sizeof(bytes);
        lastError = IOHIDDeviceGetReport(sensor, kIOHIDReportTypeFeature,
                                       ids[i], bytes, &length);
        if (lastError != kIOReturnSuccess || bytes[0] != ids[i]) continue;
        double angle = NAN;
        if (ids[i] == 7 && length >= 5) {
            uint32_t raw = (uint32_t)bytes[1] | ((uint32_t)bytes[2] << 8) |
                           ((uint32_t)bytes[3] << 16) | ((uint32_t)bytes[4] << 24);
            angle = raw / 100.0;
        } else if (ids[i] == 1 && length >= 3) {
            angle = (uint16_t)bytes[1] | ((uint16_t)bytes[2] << 8);
        }
        if (isfinite(angle) && angle >= 0 && angle <= 360) {
            fineResolution = ids[i] == 7;
            return angle;
        }
    }
    return NAN;
}

static void disconnectSensor(void) {
    if (sensor) { IOHIDDeviceClose(sensor, 0); CFRelease(sensor); sensor = NULL; }
    if (manager) { IOHIDManagerClose(manager, 0); CFRelease(manager); manager = NULL; }
}


static NSString *fileError(NSError *error) {
    if (!error) return @"The file operation failed.";
    if ([error.domain isEqualToString:@"LidAngle"]) return error.localizedDescription;
    return [NSString stringWithFormat:@"The file operation failed (%@, code %ld).",error.domain,(long)error.code];
}

static NSString *recordsOverride;
static NSString *previewPath;
static BOOL selfCheck;

static NSDateFormatter *dateFormat(NSString *format) {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    f.timeZone = [NSTimeZone localTimeZone];
    f.dateFormat = format;
    return f;
}

@interface AngleChart : NSView
@property(nonatomic) NSArray<NSDictionary *> *samples;
@end
@implementation AngleChart
- (void)setSamples:(NSArray<NSDictionary *> *)samples { _samples = [samples copy]; self.needsDisplay = YES; }
- (void)drawRect:(NSRect)dirty {
    [[NSColor controlBackgroundColor] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:12 yRadius:12] fill];
    NSRect plot = NSInsetRect(self.bounds, 48, 30);
    plot.origin.x += 6; plot.size.width -= 12;
    NSDictionary *attrs = @{NSFontAttributeName:[NSFont systemFontOfSize:11], NSForegroundColorAttributeName:[NSColor secondaryLabelColor]};
    NSDate *end = self.samples.lastObject[@"date"] ?: [NSDate date];
    NSTimeInterval finish = end.timeIntervalSince1970;
    double ceiling = 135;
    for (NSDictionary *s in self.samples) if (s[@"angle"] != [NSNull null]) ceiling = fmax(ceiling, ceil([s[@"angle"] doubleValue] / 45) * 45);
    for (int i = 0; i <= 3; i++) {
        CGFloat y = plot.origin.y + plot.size.height * i / 3;
        [[NSColor separatorColor] setStroke];
        NSBezierPath *grid = [NSBezierPath bezierPath];
        [grid moveToPoint:NSMakePoint(plot.origin.x,y)]; [grid lineToPoint:NSMakePoint(NSMaxX(plot),y)]; [grid stroke];
        [[NSString stringWithFormat:@"%.0f°", ceiling * i / 3] drawAtPoint:NSMakePoint(8,y-6) withAttributes:attrs];
    }
    CGFloat reference = plot.origin.y + plot.size.height * closeReferenceDegrees / ceiling;
    NSBezierPath *threshold = [NSBezierPath bezierPath]; CGFloat dash[] = {4,4};
    [threshold setLineDash:dash count:2 phase:0];
    [threshold moveToPoint:NSMakePoint(plot.origin.x,reference)]; [threshold lineToPoint:NSMakePoint(NSMaxX(plot),reference)];
    [[NSColor systemOrangeColor] setStroke]; [threshold stroke];
    NSBezierPath *line = [NSBezierPath bezierPath]; line.lineWidth = 2.3;
    BOOL pen = NO; NSTimeInterval previousTime = 0;
    for (NSDictionary *s in self.samples) {
        NSTimeInterval time = [s[@"date"] timeIntervalSince1970];
        if (time < finish - 60) continue;
        if (s[@"angle"] == [NSNull null]) { pen = NO; continue; }
        NSPoint p = NSMakePoint(plot.origin.x + plot.size.width * (time - (finish-60)) / 60,
                               plot.origin.y + plot.size.height * [s[@"angle"] doubleValue] / ceiling);
        if (!pen || time - previousTime > 2) [line moveToPoint:p]; else [line lineToPoint:p];
        pen = YES; previousTime = time;
    }
    [[NSColor controlAccentColor] setStroke]; [line stroke];
    [@"60s ago" drawAtPoint:NSMakePoint(plot.origin.x,9) withAttributes:attrs];
    [[dateFormat(@"HH:mm:ss") stringFromDate:end] drawAtPoint:NSMakePoint(NSMaxX(plot)-49,9) withAttributes:attrs];
    if (!self.samples.count) [@"Waiting for measurements..." drawAtPoint:NSMakePoint(plot.origin.x+130,NSMidY(plot)) withAttributes:attrs];
}
@end

@interface RecorderBackground : NSView
@end
@implementation RecorderBackground
- (void)drawRect:(NSRect)dirty { [NSColor.windowBackgroundColor setFill]; NSRectFill(self.bounds); }
@end

@interface RecorderButton : NSButton
@end
@implementation RecorderButton
- (void)drawRect:(NSRect)dirty {
    [(self.highlighted?NSColor.selectedControlColor:NSColor.controlColor) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,1,2) xRadius:6 yRadius:6] fill];
    NSDictionary *attrs=@{NSFontAttributeName:[NSFont systemFontOfSize:13],NSForegroundColorAttributeName:NSColor.labelColor};
    NSSize size=[self.title sizeWithAttributes:attrs];
    [self.title drawAtPoint:NSMakePoint((self.bounds.size.width-size.width)/2,(self.bounds.size.height-size.height)/2) withAttributes:attrs];
}
@end

@interface RecorderPopupCell : NSPopUpButtonCell
@end
@implementation RecorderPopupCell
- (void)drawWithFrame:(NSRect)frame inView:(NSView *)view {
    [NSColor.controlColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(frame,1,2) xRadius:6 yRadius:6] fill];
    NSDictionary *attrs=@{NSFontAttributeName:[NSFont systemFontOfSize:13],NSForegroundColorAttributeName:NSColor.labelColor};
    [NSGraphicsContext saveGraphicsState]; NSRectClip(NSInsetRect(frame,10,0));
    [self.title drawAtPoint:NSMakePoint(frame.origin.x+10,NSMidY(frame)-8) withAttributes:attrs];
    [NSGraphicsContext restoreGraphicsState];
    NSBezierPath *arrow=[NSBezierPath bezierPath];
    [arrow moveToPoint:NSMakePoint(NSMaxX(frame)-19,NSMidY(frame)+2)];
    [arrow lineToPoint:NSMakePoint(NSMaxX(frame)-11,NSMidY(frame)+2)];
    [arrow lineToPoint:NSMakePoint(NSMaxX(frame)-15,NSMidY(frame)-3)];
    [arrow closePath]; [NSColor.secondaryLabelColor setFill]; [arrow fill];
}
@end

@interface Recorder : NSObject <NSApplicationDelegate,NSTableViewDataSource,NSTableViewDelegate>
@property NSWindow *window;
@property NSTextField *angleLabel, *sensorLabel, *recordLabel, *statsLabel, *footer;
@property NSButton *recordButton;
@property NSPopUpButton *sessionPicker;
@property NSTableView *table;
@property AngleChart *chart;
@property NSMutableArray<NSDictionary *> *liveRows;
@property NSArray<NSDictionary *> *shownRows;
@property NSArray<NSURL *> *sessionURLs;
@property NSURL *directory, *activeURL;
@property NSDateFormatter *timestampFormat;
@property NSTimer *timer;
@property dispatch_queue_t sensorQueue;
@property BOOL recording, polling, quitting;
@property NSDate *lastReconnect;
@property FILE *logFile;
@property NSUInteger writtenRows;
@end

@implementation Recorder
- (NSTextField *)label:(NSString *)text rect:(NSRect)rect size:(CGFloat)size weight:(NSFontWeight)weight {
    NSTextField *label = [NSTextField labelWithString:text]; label.frame=rect;
    label.font=[NSFont systemFontOfSize:size weight:weight];
    [self.window.contentView addSubview:label]; return label;
}
- (NSButton *)button:(NSString *)title x:(CGFloat)x width:(CGFloat)width action:(SEL)action {
    NSButton *b=[RecorderButton buttonWithTitle:title target:self action:action];
    b.frame=NSMakeRect(x,351,width,32); b.bezelStyle=NSBezelStyleRounded;
    [self.window.contentView addSubview:b]; return b;
}
- (void)showError:(NSString *)message {
    NSAlert *alert=[NSAlert new]; alert.messageText=@"Unable to process recordings"; alert.informativeText=message;
    [alert addButtonWithTitle:@"OK"];
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}
- (void)installMenu {
    NSMenu *menu=[NSMenu new]; NSMenuItem *appItem=[NSMenuItem new]; [menu addItem:appItem];
    NSMenu *appMenu=[NSMenu new];
    [appMenu addItemWithTitle:@"Quit Lid Angle Recorder" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu=appMenu;
    NSMenuItem *editItem=[NSMenuItem new]; editItem.title=@"Edit"; [menu addItem:editItem];
    NSMenu *edit=[NSMenu new]; [edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"]; editItem.submenu=edit;
    NSMenuItem *windowItem=[NSMenuItem new]; windowItem.title=@"Window"; [menu addItem:windowItem];
    NSMenu *win=[NSMenu new]; [win addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    windowItem.submenu=win; NSApp.windowsMenu=win; NSApp.mainMenu=menu;
}
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    self.sensorQueue=dispatch_queue_create("local.lidangle.sensor",DISPATCH_QUEUE_SERIAL);
    self.liveRows=[NSMutableArray new]; self.shownRows=@[];
    self.timestampFormat=dateFormat(@"yyyy-MM-dd'T'HH:mm:ss.SSSXXX");
    NSURL *support=[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *defaultDirectory=[[support URLByAppendingPathComponent:@"Lid Angle Recorder" isDirectory:YES] URLByAppendingPathComponent:@"Recordings" isDirectory:YES];
    self.directory=recordsOverride ? [NSURL fileURLWithPath:recordsOverride isDirectory:YES] : defaultDirectory;
    self.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,900,750)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title=@"Lid Angle Recorder"; self.window.releasedWhenClosed=NO; [self.window center];
    self.window.contentView=[[RecorderBackground alloc] initWithFrame:NSMakeRect(0,0,900,750)];
    [self installMenu];
    [self label:@"Lid Angle Recorder" rect:NSMakeRect(28,694,500,32) size:24 weight:NSFontWeightSemibold];
    [self label:@"Measure the hinge angle and keep a timestamped history." rect:NSMakeRect(29,667,700,23) size:13 weight:NSFontWeightRegular];
    self.angleLabel=[self label:@"—" rect:NSMakeRect(25,555,450,104) size:78 weight:NSFontWeightMedium];
    self.angleLabel.font=[NSFont monospacedDigitSystemFontOfSize:78 weight:NSFontWeightMedium];
    self.sensorLabel=[self label:@"Connecting to sensor..." rect:NSMakeRect(480,618,390,24) size:14 weight:NSFontWeightMedium];
    self.recordLabel=[self label:@"Preparing automatic recording" rect:NSMakeRect(480,586,390,24) size:14 weight:NSFontWeightRegular];
    [self label:@"Closed 0° · Upright 90° · Sample interval 0.2s" rect:NSMakeRect(29,540,830,24) size:13 weight:NSFontWeightRegular];
    [self label:@"Last 60 seconds" rect:NSMakeRect(29,510,200,23) size:14 weight:NSFontWeightSemibold];
    [self label:[NSString stringWithFormat:@"Orange dashed line: close reference %.0f°",closeReferenceDegrees] rect:NSMakeRect(570,510,310,23) size:12 weight:NSFontWeightRegular];
    self.chart=[[AngleChart alloc] initWithFrame:NSMakeRect(28,395,844,112)]; [self.window.contentView addSubview:self.chart];
    self.recordButton=[self button:@"Pause recording" x:28 width:136 action:@selector(toggleRecording:)];
    [self button:@"New session" x:172 width:100 action:@selector(newSession:)];
    [self button:@"Import CSV..." x:280 width:114 action:@selector(importCSV:)];
    [self button:@"Recordings" x:402 width:114 action:@selector(openFolder:)];
    [self button:@"Show CSV" x:524 width:140 action:@selector(revealCSV:)];
    [self label:@"History" rect:NSMakeRect(29,316,90,24) size:14 weight:NSFontWeightSemibold];
    self.sessionPicker=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(122,313,750,29) pullsDown:NO];
    self.sessionPicker.cell=[[RecorderPopupCell alloc] initTextCell:@"" pullsDown:NO];
    self.sessionPicker.target=self; self.sessionPicker.action=@selector(selectSession:);
    [self.window.contentView addSubview:self.sessionPicker];
    self.statsLabel=[self label:@"Waiting for recordings" rect:NSMakeRect(29,282,840,23) size:12 weight:NSFontWeightRegular];
    NSScrollView *scroll=[[NSScrollView alloc] initWithFrame:NSMakeRect(28,63,844,210)];
    scroll.hasVerticalScroller=YES; scroll.borderType=NSBezelBorder;
    self.table=[[NSTableView alloc] initWithFrame:scroll.bounds]; self.table.rowHeight=25;
    self.table.usesAlternatingRowBackgroundColors=YES; self.table.dataSource=self; self.table.delegate=self;
    NSArray *columns=@[@[@"time",@"Timestamp (local time)",@330],@[@"angle",@"Lid angle",@150],@[@"resolution",@"Resolution",@130],@[@"status",@"Status",@200]];
    for(NSArray *c in columns) { NSTableColumn *col=[[NSTableColumn alloc] initWithIdentifier:c[0]]; col.title=c[1]; col.width=[c[2] doubleValue]; [self.table addTableColumn:col]; }
    scroll.documentView=self.table; [self.window.contentView addSubview:scroll];
    self.footer=[self label:@"Newest rows at bottom · Auto-scroll · Table: last 5,000 rows · CSV: all rows\nResolution is not accuracy. This app does not control display sleep or system sleep."
                     rect:NSMakeRect(29,12,842,42) size:11 weight:NSFontWeightRegular];
    self.footer.maximumNumberOfLines=2; self.footer.textColor=NSColor.secondaryLabelColor;
    [self.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    NSError *error=nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:self.directory withIntermediateDirectories:YES attributes:nil error:&error]) [self showError:fileError(error)];
    else [self newSession:nil];
    [self refreshSessions];
    self.timer=[NSTimer scheduledTimerWithTimeInterval:0.2 target:self selector:@selector(poll) userInfo:nil repeats:YES];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(didWake:) name:NSWorkspaceDidWakeNotification object:nil];
    [self poll];
    if (selfCheck) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{ [self validateRecording]; });
    else if (previewPath) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{ [self savePreview]; [NSApp terminate:nil]; });
}
- (void)savePreview {
    if(!previewPath) return;
    NSView *view=self.window.contentView;
    NSBitmapImageRep *rep=[view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
    NSData *png=[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    BOOL saved=[png writeToFile:previewPath atomically:YES];
    NSCAssert(saved,@"Preview PNG could not be saved");
    NSLog(@"Preview: %@; rows: %lu",previewPath,(unsigned long)self.liveRows.count);
}
- (void)validateRecording {
    NSCAssert(self.writtenRows>2,@"No live sensor records were saved");
    NSArray *parsed=[self readRows:self.activeURL error:nil];
    NSCAssert(parsed.count==self.writtenRows,@"Saved CSV rows do not match live rows");
    BOOL valid=NO; for(NSDictionary *r in parsed) if(r[@"angle"]!=NSNull.null) valid=YES;
    NSCAssert(valid,@"Sensor did not return a valid angle");
    [self savePreview];
    NSURL *original=self.activeURL;
    NSData *before=[NSData dataWithContentsOfURL:original];
    NSUInteger pausedCount=self.writtenRows;
    [self toggleRecording:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{
        NSCAssert(!self.recording && self.writtenRows==pausedCount,@"Pause continued recording");
        NSCAssert([before isEqualToData:[NSData dataWithContentsOfURL:original]],@"Paused CSV changed");
        [self toggleRecording:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{
            NSCAssert(self.recording && self.writtenRows>pausedCount,@"Resume did not save records");
            [self newSession:nil];
            NSCAssert(![self.activeURL isEqual:original],@"New session reused the previous file");
            NSUInteger index=[self.sessionURLs indexOfObject:original];
            NSCAssert(index!=NSNotFound,@"Previous session is missing");
            [self.sessionPicker selectItemAtIndex:index+1]; [self selectSession:nil];
            NSCAssert(self.shownRows.count>pausedCount,@"Previous CSV did not load");
            NSLog(@"PASS: live sensor, CSV round trip, pause, resume, new session, history reload");
            [NSApp terminate:nil];
        });
    });
}
- (void)didWake:(NSNotification *)note {
    dispatch_async(self.sensorQueue,^{ disconnectSensor(); });
}
- (void)poll {
    if(self.polling || self.quitting) return;
    self.polling=YES;
    dispatch_async(self.sensorQueue,^{
        if(!sensor) {
            if(!self.lastReconnect || -self.lastReconnect.timeIntervalSinceNow >= 3) {
                disconnectSensor(); connectSensor(); self.lastReconnect=[NSDate date];
            }
        }
        double angle=sensor ? readAngle() : NAN;
        BOOL fine=fineResolution; IOReturn err=lastError;
        NSDate *date=[NSDate date];
        if(!isfinite(angle)) disconnectSensor();
        dispatch_async(dispatch_get_main_queue(),^{
            self.polling=NO; if(self.quitting) return;
            [self acceptAngle:angle fine:fine error:err date:date];
        });
    });
}
- (void)acceptAngle:(double)angle fine:(BOOL)fine error:(IOReturn)error date:(NSDate *)date {
    BOOL valid=isfinite(angle);
    NSString *timestamp=[self.timestampFormat stringFromDate:date];
    NSString *state=valid ? @"ok" : [NSString stringWithFormat:@"error_0x%08x",error];
    NSDictionary *row=@{@"time":timestamp,@"date":date,@"angle":valid?@(angle):[NSNull null],@"resolution":valid?(fine?@"0.01":@"1"):@"",@"status":state};
    self.angleLabel.stringValue=valid?[NSString stringWithFormat:fine?@"%.2f°":@"%.0f°",angle]:@"—";
    self.sensorLabel.stringValue=valid?@"● Sensor connected · Live":[NSString stringWithFormat:@"Reconnecting to sensor (0x%08x)",error];
    self.sensorLabel.textColor=valid?NSColor.systemGreenColor:NSColor.systemOrangeColor;
    if(self.recording && self.logFile) {
        NSString *line=[NSString stringWithFormat:@"%@,%@,%@,%@\n",timestamp,valid?[NSString stringWithFormat:@"%.2f",angle]:@"",row[@"resolution"],state];
        const char *bytes=line.UTF8String;
        BOOL saved=fputs(bytes,self.logFile)!=EOF && fflush(self.logFile)==0;
        if(!saved) {
            [self closeLog]; self.recording=NO; self.recordButton.title=@"Resume recording";
            [self showError:@"Could not save the CSV. Check free disk space and recording folder permissions."];
        } else {
            [self.liveRows addObject:row]; self.writtenRows++;
            if(self.liveRows.count>5000) [self.liveRows removeObjectAtIndex:0];
        }
    }
    self.recordLabel.stringValue=self.recording?[NSString stringWithFormat:@"● Recording · %lu rows saved",(unsigned long)self.writtenRows]:@"Recording paused · Sensor remains live";
    if(self.sessionPicker.indexOfSelectedItem==0) [self updateVisibleRows];
}
- (void)closeLog { if(self.logFile) { fflush(self.logFile); fclose(self.logFile); self.logFile=NULL; } }
- (BOOL)openLog:(NSURL *)url {
    self.logFile=fopen(url.fileSystemRepresentation,"a");
    if(!self.logFile) { [self showError:@"Could not open the CSV. Check recording folder permissions."]; return NO; }
    fseek(self.logFile,0,SEEK_END);
    if(ftell(self.logFile)==0 && (fputs("timestamp,angle_degrees,resolution_degrees,status\n",self.logFile)==EOF || fflush(self.logFile)!=0)) {
        [self closeLog]; [self showError:@"Could not write the CSV header."]; return NO;
    }
    return YES;
}
- (void)newSession:(id)sender {
    NSString *name=[NSString stringWithFormat:@"lid-angle-%@-%@.csv",[dateFormat(@"yyyyMMdd-HHmmss") stringFromDate:[NSDate date]],[[NSUUID UUID].UUIDString substringToIndex:6]];
    NSURL *url=[self.directory URLByAppendingPathComponent:name];
    [self closeLog]; self.recording=NO;
    if(![self openLog:url]) { self.recordButton.title=@"Resume recording"; return; }
    self.activeURL=url; self.recording=YES; self.writtenRows=0; [self.liveRows removeAllObjects];
    self.recordButton.title=@"Pause recording";
    [self refreshSessions]; [self.sessionPicker selectItemAtIndex:0]; [self updateVisibleRows];
}
- (void)toggleRecording:(id)sender {
    if(self.recording) { [self closeLog]; self.recording=NO; }
    else if(self.activeURL) self.recording=[self openLog:self.activeURL];
    else { [self newSession:nil]; return; }
    self.recordButton.title=self.recording?@"Pause recording":@"Resume recording";
    self.recordLabel.stringValue=self.recording?@"● Recording":@"Recording paused · Sensor remains live";
}
- (void)refreshSessions {
    NSURL *selected=[self selectedURL];
    NSArray *all=[NSFileManager.defaultManager contentsOfDirectoryAtURL:self.directory includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    NSPredicate *predicate=[NSPredicate predicateWithBlock:^BOOL(NSURL *url,NSDictionary *bindings){ return [url.pathExtension.lowercaseString isEqualToString:@"csv"] && ![url isEqual:self.activeURL]; }];
    self.sessionURLs=[[all filteredArrayUsingPredicate:predicate] sortedArrayUsingComparator:^NSComparisonResult(NSURL *a,NSURL *b){ return [b.lastPathComponent compare:a.lastPathComponent]; }];
    [self.sessionPicker removeAllItems]; [self.sessionPicker addItemWithTitle:@"Live · Current session"];
    for(NSURL *url in self.sessionURLs) [self.sessionPicker addItemWithTitle:url.lastPathComponent];
    if(selected && ![selected isEqual:self.activeURL]) {
        NSUInteger i=[self.sessionURLs indexOfObject:selected];
        if(i!=NSNotFound) [self.sessionPicker selectItemAtIndex:i+1];
    }
}
- (NSURL *)selectedURL {
    NSInteger i=self.sessionPicker.indexOfSelectedItem;
    return i>0 && (NSUInteger)(i-1)<self.sessionURLs.count?self.sessionURLs[i-1]:self.activeURL;
}
- (NSArray *)readRows:(NSURL *)url error:(NSError **)error {
    NSFileHandle *handle=[NSFileHandle fileHandleForReadingFromURL:url error:error];
    if(!handle) return nil;
    unsigned long long size=[handle seekToEndOfFile]; BOOL partial=size>2*1024*1024;
    [handle seekToFileOffset:partial?size-2*1024*1024:0];
    NSData *data=[handle readDataToEndOfFile]; [handle closeFile];
    NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if(!text) { if(error) *error=[NSError errorWithDomain:@"LidAngle" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Only UTF-8 CSV files are supported."}]; return nil; }
    NSArray *lines=[text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    NSMutableArray *rows=[NSMutableArray new];
    for(NSUInteger i=partial?1:0;i<lines.count;i++) {
        NSArray *parts=[lines[i] componentsSeparatedByString:@","]; if(parts.count!=4) continue;
        NSDate *date=[self.timestampFormat dateFromString:parts[0]]; if(!date) continue;
        double angle=0; NSScanner *scanner=[NSScanner scannerWithString:parts[1]];
        scanner.locale=[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        BOOL valid=[parts[3] isEqualToString:@"ok"] && [scanner scanDouble:&angle] && scanner.isAtEnd && isfinite(angle) && angle>=0 && angle<=360;
        if([parts[3] isEqualToString:@"ok"] && !valid) continue;
        [rows addObject:@{@"time":parts[0],@"date":date,@"angle":valid?@(angle):[NSNull null],@"resolution":parts[2],@"status":parts[3]}];
    }
    if(rows.count>5000) [rows removeObjectsInRange:NSMakeRange(0,rows.count-5000)];
    return rows;
}
- (void)selectSession:(id)sender {
    if(self.sessionPicker.indexOfSelectedItem==0) { [self updateVisibleRows]; return; }
    NSError *error=nil; NSArray *rows=[self readRows:[self selectedURL] error:&error];
    if(!rows) { [self showError:fileError(error)]; return; }
    self.shownRows=rows; [self displayRows];
}
- (void)updateVisibleRows { self.shownRows=[self.liveRows copy]; [self displayRows]; }
- (void)displayRows {
    [self.table reloadData];
    if(self.shownRows.count) [self.table scrollRowToVisible:self.shownRows.count-1];
    self.chart.samples=self.shownRows;
    double minimum=INFINITY,maximum=-INFINITY,total=0; NSUInteger count=0;
    for(NSDictionary *row in self.shownRows) if(row[@"angle"]!=[NSNull null]) { double a=[row[@"angle"] doubleValue]; minimum=fmin(minimum,a); maximum=fmax(maximum,a); total+=a; count++; }
    self.statsLabel.stringValue=count?[NSString stringWithFormat:@"%lu rows · Min %.2f° · Max %.2f° · Mean %.2f° · %@",(unsigned long)self.shownRows.count,minimum,maximum,total/count,self.sessionPicker.indexOfSelectedItem==0?@"Current session":@"Historical session · Live angle above"]:@"No valid measurements yet";
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return self.shownRows.count; }
- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)index {
    NSDictionary *row=self.shownRows[index]; NSString *key=column.identifier;
    NSString *value=@"";
    if([key isEqualToString:@"time"]) value=[row[@"time"] stringByReplacingOccurrencesOfString:@"T" withString:@" "];
    if([key isEqualToString:@"angle"]) value=row[@"angle"]==[NSNull null]?@"—":[NSString stringWithFormat:@"%.2f°",[row[@"angle"] doubleValue]];
    if([key isEqualToString:@"resolution"]) value=[row[@"resolution"] length]?[row[@"resolution"] stringByAppendingString:@"°"]:@"—";
    if([key isEqualToString:@"status"]) value=[row[@"status"] isEqualToString:@"ok"]?@"OK":row[@"status"];
    NSTextField *field=[tableView makeViewWithIdentifier:key owner:self];
    if(!field) { field=[NSTextField labelWithString:@""]; field.identifier=key; field.font=[NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular]; }
    field.stringValue=value; field.toolTip=value; return field;
}
- (void)openFolder:(id)sender { [NSWorkspace.sharedWorkspace openURL:self.directory]; }
- (void)revealCSV:(id)sender { NSURL *url=[self selectedURL]; if(url) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[url]]; }
- (void)importCSV:(id)sender {
    NSOpenPanel *panel=[NSOpenPanel openPanel]; panel.canChooseDirectories=NO; panel.allowsMultipleSelection=NO;
    panel.title=@"Import CSV"; panel.prompt=@"Import";
    panel.message=@"Choose a CSV saved by Lid Angle Recorder or its terminal logger.";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result){
        if(result!=NSModalResponseOK) return;
        NSError *error=nil; NSArray *rows=[self readRows:panel.URL error:&error];
        if(!rows.count) { [self showError:error ? fileError(error) : @"No recognizable angle records were found."]; return; }
        NSString *name=[NSString stringWithFormat:@"import-%@-%@",[[NSUUID UUID].UUIDString substringToIndex:6],panel.URL.lastPathComponent];
        if(![name.pathExtension.lowercaseString isEqualToString:@"csv"]) name=[name stringByAppendingString:@".csv"];
        NSURL *destination=[self.directory URLByAppendingPathComponent:name];
        if(![NSFileManager.defaultManager copyItemAtURL:panel.URL toURL:destination error:&error]) { [self showError:fileError(error)]; return; }
        [self refreshSessions]; NSUInteger i=[self.sessionURLs indexOfObject:destination];
        if(i!=NSNotFound) { [self.sessionPicker selectItemAtIndex:i+1]; [self selectSession:nil]; }
    }];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return YES; }
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag { [self.window makeKeyAndOrderFront:nil]; return YES; }
- (void)applicationWillTerminate:(NSNotification *)note {
    self.quitting=YES; [self.timer invalidate]; [self closeLog];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
    dispatch_sync(self.sensorQueue,^{disconnectSensor();});
}
@end

int main(int argc,const char *argv[]) {
    @autoreleasepool {
        for(int i=1;i<argc;i++) {
            if(strcmp(argv[i],"--self-check")==0) selfCheck=YES;
            else if(strcmp(argv[i],"--records-directory")==0 && i+1<argc) recordsOverride=@(argv[++i]);
            else if(strcmp(argv[i],"--preview")==0 && i+1<argc) previewPath=@(argv[++i]);
            else if(strcmp(argv[i],"--once")==0) {
                BOOL ready=connectSensor(); double angle=ready?readAngle():NAN;
                if(isfinite(angle)) printf("Hinge angle: %.2f degrees\n",angle); else fprintf(stderr,"Sensor error: 0x%08x\n",lastError);
                disconnectSensor(); return isfinite(angle)?0:1;
            }
        }
        NSApplication *app=NSApplication.sharedApplication; [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        Recorder *recorder=[Recorder new]; app.delegate=recorder; [app run];
    }
    return 0;
}
