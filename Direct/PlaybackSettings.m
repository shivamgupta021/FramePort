#import "PlaybackSettings.h"

static NSString *const FilterKey = @"resizeFilter";
static NSString *const SharpnessKey = @"sharpeningLevel";
static NSString *const EngineKey = @"interpolationEngine";
static NSString *const FullScreenKey = @"startFullScreen";

@implementation PlaybackSettings {
    NSUserDefaults *_defaults;
}

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
    if (!(self = [super initWithWindow:nil])) return nil;
    _defaults = defaults;
    [_defaults registerDefaults:@{FilterKey:@(FPResizeLanczos), SharpnessKey:@1, FullScreenKey:@YES, EngineKey:@"detail"}];
    self.window = [self makePanel];
    return self;
}
- (NSInteger)sharpnessLevel {
    NSInteger value = [_defaults integerForKey:SharpnessKey];
    return value >= 0 && value <= 2 ? value : 1;
}
- (FPPictureOptions)pictureOptions {
    FPPictureOptions options = FPDetailPictureOptions();
    if ([_defaults integerForKey:FilterKey] == FPResizeBilinear) options.filter = FPResizeBilinear;
    switch (self.sharpnessLevel) {
        case 0: options.sharpness = 0; break;
        case 2: options.sharpness = 0.35; break;
    }
    return options;
}
- (FPGenerationEngine)generationEngine {
    return [[_defaults stringForKey:EngineKey] isEqualToString:@"metal"] ? FPGenerationMetalNative : FPGenerationGuided;
}
- (BOOL)startsFullScreen { return [_defaults boolForKey:FullScreenKey]; }

- (NSPopUpButton *)popup:(NSArray<NSString *> *)items selection:(NSInteger)selection action:(SEL)action {
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [popup addItemsWithTitles:items];
    [popup selectItemAtIndex:selection];
    popup.target = self;
    popup.action = action;
    return popup;
}
- (NSPanel *)makePanel {
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,440,195)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    panel.title = @"FramePort Settings";
    panel.floatingPanel = YES;
    panel.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorMoveToActiveSpace;
    NSPopUpButton *filter = [self popup:@[@"Lanczos", @"Bilinear"] selection:self.pictureOptions.filter action:@selector(changeFilter:)];
    NSPopUpButton *sharpen = [self popup:@[@"Off", @"Mild", @"Strong"] selection:self.sharpnessLevel action:@selector(changeSharpness:)];
    NSPopUpButton *engine = [self popup:@[@"Detail (Apple + Metal)", @"Fast Metal (experimental)"]
        selection:self.generationEngine == FPGenerationMetalNative ? 1 : 0 action:@selector(changeEngine:)];
    [engine setAccessibilityLabel:@"Frame interpolation"];
    engine.toolTip = @"Fast Metal estimates motion in blocks. Camera turns and thin edges may show artifacts.";
    NSButton *full = [NSButton checkboxWithTitle:@"Start in full screen" target:self action:@selector(changeStartup:)];
    full.state = self.startsFullScreen ? NSControlStateValueOn : NSControlStateValueOff;
    [filter setAccessibilityLabel:@"Enlargement filter"];
    [sharpen setAccessibilityLabel:@"Sharpening"];
    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[[NSTextField labelWithString:@"Enlargement filter"], filter],
        @[[NSTextField labelWithString:@"Sharpening"], sharpen],
        @[[NSTextField labelWithString:@"Frame interpolation"], engine],
        @[[NSGridCell emptyContentView], full]
    ]];
    grid.rowSpacing = 12;
    grid.columnSpacing = 18;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    [grid columnAtIndex:1].xPlacement = NSGridCellPlacementLeading;
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    [panel.contentView addSubview:grid];
    [NSLayoutConstraint activateConstraints:@[
        [grid.centerXAnchor constraintEqualToAnchor:panel.contentView.centerXAnchor],
        [grid.centerYAnchor constraintEqualToAnchor:panel.contentView.centerYAnchor]
    ]];
    [panel center];
    return panel;
}
- (void)changeFilter:(NSPopUpButton *)sender {
    [_defaults setInteger:sender.indexOfSelectedItem forKey:FilterKey];
    if (self.pictureDidChange) self.pictureDidChange(self.pictureOptions);
}
- (void)changeSharpness:(NSPopUpButton *)sender {
    [_defaults setInteger:sender.indexOfSelectedItem forKey:SharpnessKey];
    if (self.pictureDidChange) self.pictureDidChange(self.pictureOptions);
}
- (void)changeEngine:(NSPopUpButton *)sender {
    [_defaults setObject:sender.indexOfSelectedItem == 1 ? @"metal" : @"detail" forKey:EngineKey];
    if (self.engineDidChange) self.engineDidChange(self.generationEngine);
}
- (void)changeStartup:(NSButton *)sender {
    [_defaults setBool:sender.state == NSControlStateValueOn forKey:FullScreenKey];
}
@end
