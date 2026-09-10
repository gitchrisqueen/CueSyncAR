#import <Foundation/Foundation.h>

#if __has_attribute(swift_private)
#define AC_SWIFT_PRIVATE __attribute__((swift_private))
#else
#define AC_SWIFT_PRIVATE
#endif

/// The resource bundle ID.
static NSString * const ACBundleID AC_SWIFT_PRIVATE = @"CQC.CueSync-AR";

/// The "AccentColor" asset catalog color resource.
static NSString * const ACColorNameAccentColor AC_SWIFT_PRIVATE = @"AccentColor";

/// The "LaunchBackground" asset catalog color resource.
static NSString * const ACColorNameLaunchBackground AC_SWIFT_PRIVATE = @"LaunchBackground";

#undef AC_SWIFT_PRIVATE
