#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

// Compiled into both SpringBoard and the preference bundle.  Each process runs
// this before opening its defaults; the old domain is never modified or removed.
__attribute__((constructor)) static void LPSBMigrateLegacyPreferences(void) {
    @autoreleasepool {
        CFStringRef destination = CFSTR("com.82flex.letterpress");
        CFStringRef source = CFSTR("wiki.qaq.letterpress");
        CFStringRef marker = CFSTR("_letterpressLegacyDomainMigratedV1");
        CFPreferencesAppSynchronize(destination);
        CFTypeRef migrated = CFPreferencesCopyAppValue(marker, destination);
        BOOL alreadyMigrated = migrated && CFEqual(migrated, kCFBooleanTrue);
        if (migrated) CFRelease(migrated);
        if (alreadyMigrated) return;

        CFPreferencesAppSynchronize(source);
        NSArray<NSString *> *keys = @[
            @"isEnabled", @"shouldDisplayOnLockScreen", @"shouldDisplayWhenScreencast",
            @"isAdaptiveColorEnabled", @"isLabelEnabled", @"selectedApplications",
            @"selectedApplicationsCSV", @"widthRatio", @"yOffset", @"ySlide",
            @"fontSize", @"opacity", @"birthRate", @"lifespan", @"speed",
            @"speedVariation", @"initialSize", @"sizeMultiplier", @"fontType",
            @"tokenizerMode", @"labelFontSize", @"yLabelOffset", @"burstCount",
            @"burstCountVariation", @"attractionStrength", @"dampingFactor",
            @"color1", @"color2", @"color3", @"color4"
        ];
        // Array and CSV encode one option. Any explicit new-domain value,
        // including [] or @"", prevents either legacy representation migrating.
        CFPropertyListRef selectedArray = CFPreferencesCopyAppValue(CFSTR("selectedApplications"), destination);
        CFPropertyListRef selectedCSV = CFPreferencesCopyAppValue(CFSTR("selectedApplicationsCSV"), destination);
        BOOL hasApplicationSelection = selectedArray != NULL || selectedCSV != NULL;
        if (selectedArray) CFRelease(selectedArray);
        if (selectedCSV) CFRelease(selectedCSV);
        for (NSString *key in keys) {
            if (hasApplicationSelection &&
                ([key isEqualToString:@"selectedApplications"] || [key isEqualToString:@"selectedApplicationsCSV"])) continue;
            CFStringRef name = (__bridge CFStringRef)key;
            CFPropertyListRef existing = CFPreferencesCopyAppValue(name, destination);
            if (existing) { CFRelease(existing); continue; }
            CFPropertyListRef legacy = CFPreferencesCopyAppValue(name, source);
            if (legacy) {
                CFPreferencesSetAppValue(name, legacy, destination);
                CFRelease(legacy);
            }
        }
        CFPreferencesSetAppValue(marker, kCFBooleanTrue, destination);
        CFPreferencesAppSynchronize(destination);
    }
}
