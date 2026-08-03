#import "IOSFrameRateController.h"

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const ORPowerSavingPreferenceKey = @"flutter.power_saving_mode_v1";
static NSHashTable<CADisplayLink *> *ORFlutterDisplayLinks;
static BOOL ORPowerSavingMode = NO;

@interface CADisplayLink (OpenReadingFrameRate)
+ (CADisplayLink *)or_displayLinkWithTarget:(id)target selector:(SEL)selector;
@end

@interface IOSFrameRateController ()
+ (void)captureDisplayLink:(CADisplayLink *)displayLink target:(id)target;
+ (void)applyFrameRateToDisplayLink:(CADisplayLink *)displayLink;
@end

@implementation CADisplayLink (OpenReadingFrameRate)

+ (CADisplayLink *)or_displayLinkWithTarget:(id)target selector:(SEL)selector {
  CADisplayLink *displayLink = [self or_displayLinkWithTarget:target selector:selector];
  [IOSFrameRateController captureDisplayLink:displayLink target:target];
  return displayLink;
}

@end

@implementation IOSFrameRateController

+ (void)load {
  ORPowerSavingMode = [NSUserDefaults.standardUserDefaults boolForKey:ORPowerSavingPreferenceKey];
  ORFlutterDisplayLinks = [NSHashTable weakObjectsHashTable];

  Method originalMethod = class_getClassMethod(
      CADisplayLink.class,
      NSSelectorFromString(@"displayLinkWithTarget:selector:"));
  Method replacementMethod = class_getClassMethod(
      CADisplayLink.class,
      @selector(or_displayLinkWithTarget:selector:));
  if (originalMethod != NULL && replacementMethod != NULL) {
    method_exchangeImplementations(originalMethod, replacementMethod);
  }
}

+ (void)setPowerSavingMode:(BOOL)enabled {
  ORPowerSavingMode = enabled;
  for (CADisplayLink *displayLink in ORFlutterDisplayLinks.allObjects) {
    [self applyFrameRateToDisplayLink:displayLink];
  }
}

+ (void)captureDisplayLink:(CADisplayLink *)displayLink target:(id)target {
  NSString *targetClassName = NSStringFromClass([target class]);
  if (![targetClassName hasSuffix:@"VSyncClient"]) {
    return;
  }
  [ORFlutterDisplayLinks addObject:displayLink];
  [self applyFrameRateToDisplayLink:displayLink];
#if DEBUG
  NSLog(@"Captured Flutter display link; powerSaving=%@", ORPowerSavingMode ? @"YES" : @"NO");
#endif
}

+ (void)applyFrameRateToDisplayLink:(CADisplayLink *)displayLink {
  NSInteger maximum = MAX(UIScreen.mainScreen.maximumFramesPerSecond, 60);
  NSInteger target = ORPowerSavingMode ? 60 : maximum;
  if (@available(iOS 15.0, *)) {
    NSInteger minimum = ORPowerSavingMode ? 60 : MAX(target / 2, 60);
    displayLink.preferredFrameRateRange = CAFrameRateRangeMake(
        (float)minimum,
        (float)target,
        (float)target);
  } else {
    displayLink.preferredFramesPerSecond = target;
  }
}

@end
