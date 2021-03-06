#import <AFNetworking/UIKit+AFNetworking.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <CoreTelephony/CTCarrier.h>
#import <Crashlytics/Crashlytics.h>
#import <CrashlyticsLumberjack/CrashlyticsLogger.h>
#import <DDFileLogger.h>
#import <GooglePlus/GooglePlus.h>
#import <HockeySDK/HockeySDK.h>
#import <UIDeviceIdentifier/UIDeviceHardware.h>
#import <Simperium/Simperium.h>
#import <Helpshift/Helpshift.h>
#import <Taplytics/Taplytics.h>
#import <WordPress-iOS-Shared/WPFontManager.h>

#import "WordPressAppDelegate.h"
#import "ContextManager.h"
#import "Media.h"
#import "Notification.h"
#import "NotificationsManager.h"
#import "NSString+Helpers.h"
#import "NSString+HTML.h"
#import "PocketAPI.h"
#import "ReaderPost.h"
#import "UIDevice+WordPressIdentifier.h"
#import "WordPressComApiCredentials.h"
#import "WPAccount.h"
#import "AccountService.h"
#import "BlogService.h"
#import "WPImageOptimizer.h"
#import "ReaderPostService.h"
#import "ReaderTopicService.h"
#import "SVProgressHUD.h"

#import "BlogListViewController.h"
#import "BlogDetailsViewController.h"
#import "PostsViewController.h"
#import "WPPostViewController.h"
#import "WPLegacyEditPostViewController.h"
#import "LoginViewController.h"
#import "NotificationsViewController.h"
#import "ReaderPostsViewController.h"
#import "SupportViewController.h"
#import "StatsViewController.h"
#import "Constants.h"
#import "UIImage+Util.h"

#import "WPAnalyticsTrackerMixpanel.h"
#import "WPAnalyticsTrackerWPCom.h"

#import "Reachability.h"

#if DEBUG
#import "DDTTYLogger.h"
#import "DDASLLogger.h"
#endif

int ddLogLevel                                                  = LOG_LEVEL_INFO;
static NSString * const WPTabBarRestorationID                   = @"WPTabBarID";
static NSString * const WPBlogListNavigationRestorationID       = @"WPBlogListNavigationID";
static NSString * const WPReaderNavigationRestorationID         = @"WPReaderNavigationID";
static NSString * const WPNotificationsNavigationRestorationID  = @"WPNotificationsNavigationID";
static NSString * const kUsageTrackingDefaultsKey               = @"usage_tracking_enabled";

NSInteger const kReaderTabIndex                                 = 0;
NSInteger const kNotificationsTabIndex                          = 1;
NSInteger const kMeTabIndex                                     = 2;

static NSString* const kWPNewPostURLParamTitleKey = @"title";
static NSString* const kWPNewPostURLParamContentKey = @"content";
static NSString* const kWPNewPostURLParamTagsKey = @"tags";
static NSString* const kWPNewPostURLParamImageKey = @"image";

@interface WordPressAppDelegate () <UITabBarControllerDelegate, CrashlyticsDelegate, UIAlertViewDelegate, BITHockeyManagerDelegate>

@property (nonatomic, strong, readwrite) UINavigationController         *navigationController;
@property (nonatomic, strong, readwrite) UITabBarController             *tabBarController;
@property (nonatomic, strong, readwrite) ReaderPostsViewController      *readerPostsViewController;
@property (nonatomic, strong, readwrite) BlogListViewController         *blogListViewController;
@property (nonatomic, strong, readwrite) NotificationsViewController    *notificationsViewController;
@property (nonatomic, strong, readwrite) Reachability                   *internetReachability;
@property (nonatomic, strong, readwrite) Reachability                   *wpcomReachability;
@property (nonatomic, strong, readwrite) DDFileLogger                   *fileLogger;
@property (nonatomic, strong, readwrite) Simperium                      *simperium;
@property (nonatomic, assign, readwrite) UIBackgroundTaskIdentifier     bgTask;
@property (nonatomic, assign, readwrite) BOOL                           connectionAvailable;
@property (nonatomic, assign, readwrite) BOOL                           wpcomAvailable;
@property (nonatomic, assign, readwrite) BOOL                           listeningForBlogChanges;

@end

@implementation WordPressAppDelegate

+ (WordPressAppDelegate *)sharedWordPressApplicationDelegate
{
    return (WordPressAppDelegate *)[[UIApplication sharedApplication] delegate];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - UIApplicationDelegate

- (BOOL)application:(UIApplication *)application willFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    [WordPressAppDelegate fixKeychainAccess];

    // Simperium: Wire CoreData Stack
    [self configureSimperium];

    // Crash reporting, logging
    [self configureLogging];
    [self configureHockeySDK];
    [self configureCrashlytics];

    // Start Simperium
    [self loginSimperium];

    // Debugging
    [self printDebugLaunchInfoWithLaunchOptions:launchOptions];
    [self toggleExtraDebuggingIfNeeded];
    [self removeCredentialsForDebug];

    // Stats and feedback
    [Taplytics startTaplyticsAPIKey:[WordPressComApiCredentials taplyticsAPIKey]];
    [SupportViewController checkIfFeedbackShouldBeEnabled];

    [Helpshift installForApiKey:[WordPressComApiCredentials helpshiftAPIKey] domainName:[WordPressComApiCredentials helpshiftDomainName] appID:[WordPressComApiCredentials helpshiftAppId]];
    [SupportViewController checkIfHelpshiftShouldBeEnabled];

    NSNumber *usage_tracking = [[NSUserDefaults standardUserDefaults] valueForKey:kUsageTrackingDefaultsKey];
    if (usage_tracking == nil) {
        // check if usage_tracking bool is set
        // default to YES

        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kUsageTrackingDefaultsKey];
        [NSUserDefaults resetStandardUserDefaults];
    }

    [WPAnalytics registerTracker:[[WPAnalyticsTrackerMixpanel alloc] init]];
    [WPAnalytics registerTracker:[[WPAnalyticsTrackerWPCom alloc] init]];

    if ([[NSUserDefaults standardUserDefaults] boolForKey:kUsageTrackingDefaultsKey]) {
        DDLogInfo(@"WPAnalytics session started");

        [WPAnalytics beginSession];
    }

    [[GPPSignIn sharedInstance] setClientID:[WordPressComApiCredentials googlePlusClientId]];

    // Networking setup
    [[AFNetworkActivityIndicatorManager sharedManager] setEnabled:YES];
    [self setupReachability];
    [self setupUserAgent];
    [self setupSingleSignOn];

    [self customizeAppearance];

    // Push notifications
    [NotificationsManager registerForPushNotifications];

    // Deferred tasks to speed up app launch
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        [self changeCurrentDirectory];
        [[PocketAPI sharedAPI] setConsumerKey:[WordPressComApiCredentials pocketConsumerKey]];
        [self cleanUnusedMediaFileFromTmpDir];
    });

    CGRect bounds = [[UIScreen mainScreen] bounds];
    [self.window setFrame:bounds];
    [self.window setBounds:bounds]; // for good measure.
    self.window.backgroundColor = [UIColor blackColor];
    self.window.rootViewController = self.tabBarController;

    return YES;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    DDLogVerbose(@"didFinishLaunchingWithOptions state: %d", application.applicationState);

    // Launched by tapping a notification
    if (application.applicationState == UIApplicationStateActive) {
        [NotificationsManager handleNotificationForApplicationLaunch:launchOptions];
    }

    [self.window makeKeyAndVisible];
    [self showWelcomeScreenIfNeededAnimated:NO];

    return YES;
}

- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url sourceApplication:(NSString *)sourceApplication annotation:(id)annotation
{
    BOOL returnValue = NO;

    if ([[BITHockeyManager sharedHockeyManager].authenticator handleOpenURL:url
                                                          sourceApplication:sourceApplication
                                                                 annotation:annotation]) {
        returnValue = YES;
    }

    if ([[GPPShare sharedInstance] handleURL:url sourceApplication:sourceApplication annotation:annotation]) {
        returnValue = YES;
    }

    if ([[PocketAPI sharedAPI] handleOpenURL:url]) {
        returnValue = YES;
    }

    if ([WordPressApi handleOpenURL:url]) {
        returnValue = YES;
    }

    if ([url isKindOfClass:[NSURL class]] && [[url absoluteString] hasPrefix:@"wordpress://"]) {
        NSString *URLString = [url absoluteString];
        DDLogInfo(@"Application launched with URL: %@", URLString);

        if ([URLString rangeOfString:@"newpost"].length) {
            returnValue = [self handleNewPostRequestWithURL:url];
        } else if ([URLString rangeOfString:@"viewpost"].length) {
            // View the post specified by the shared blog ID and post ID
            NSDictionary *params = [[url query] dictionaryFromQueryString];

            if (params.count) {
                NSNumber *blogId = [params numberForKey:@"blogId"];
                NSNumber *postId = [params numberForKey:@"postId"];
                
                [self.readerPostsViewController.navigationController popToRootViewControllerAnimated:NO];
                NSInteger readerTabIndex = [[self.tabBarController viewControllers] indexOfObject:self.readerPostsViewController.navigationController];
                [self.tabBarController setSelectedIndex:readerTabIndex];
                [self.readerPostsViewController openPost:postId onBlog:blogId];

                returnValue = YES;
            }
        } else if ([URLString rangeOfString:@"debugging"].length) {
            NSDictionary *params = [[url query] dictionaryFromQueryString];

            if (params.count > 0) {
                NSString *debugType = [params stringForKey:@"type"];
                NSString *debugKey = [params stringForKey:@"key"];

                if ([[WordPressComApiCredentials debuggingKey] isEqualToString:@""] || [debugKey isEqualToString:@""]) {
                    return NO;
                }

                if ([debugKey isEqualToString:[WordPressComApiCredentials debuggingKey]]) {
                    if ([debugType isEqualToString:@"crashlytics_crash"]) {
                        [[Crashlytics sharedInstance] crash];
                    }
                }
            }
		} else if ([[url host] isEqualToString:@"editor"]) {
			NSDictionary* params = [[url query] dictionaryFromQueryString];
			
			if (params.count > 0) {
				BOOL available = [[params objectForKey:kWPEditorConfigURLParamAvailable] boolValue];
				BOOL enabled = [[params objectForKey:kWPEditorConfigURLParamEnabled] boolValue];
				
				[WPPostViewController setNewEditorAvailable:available];
				[WPPostViewController setNewEditorEnabled:enabled];
                
                if (available) {
                    [WPAnalytics track:WPAnalyticsStatEditorEnabledNewVersion];
                }
				
				[self showVisualEditorAvailableInSettingsAnimation:available];
			}
        }
    }

    return returnValue;
}

- (void)applicationWillTerminate:(UIApplication *)application
{
    DDLogInfo(@"%@ %@", self, NSStringFromSelector(_cmd));
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    DDLogInfo(@"%@ %@", self, NSStringFromSelector(_cmd));

    [WPAnalytics track:WPAnalyticsStatApplicationClosed withProperties:@{@"last_visible_screen": [self currentlySelectedScreen]}];
    [WPAnalytics endSession];

    // Let the app finish any uploads that are in progress
    UIApplication *app = [UIApplication sharedApplication];
    if (_bgTask != UIBackgroundTaskInvalid) {
        [app endBackgroundTask:_bgTask];
        _bgTask = UIBackgroundTaskInvalid;
    }

    _bgTask = [app beginBackgroundTaskWithExpirationHandler:^{
        // Synchronize the cleanup call on the main thread in case
        // the task actually finishes at around the same time.
        dispatch_async(dispatch_get_main_queue(), ^{
            if (_bgTask != UIBackgroundTaskInvalid) {
                [app endBackgroundTask:_bgTask];
                _bgTask = UIBackgroundTaskInvalid;
            }
        });
    }];
}

- (NSString *)currentlySelectedScreen
{
    // Check if the post editor or login view is up
    UIViewController *rootViewController = self.window.rootViewController;
    if ([rootViewController.presentedViewController isKindOfClass:[UINavigationController class]]) {
        UINavigationController *navController = (UINavigationController *)rootViewController.presentedViewController;
        UIViewController *firstViewController = [navController.viewControllers firstObject];
        if ([firstViewController isKindOfClass:[WPPostViewController class]]) {
            return @"Post Editor";
        } else if ([firstViewController isKindOfClass:[LoginViewController class]]) {
            return @"Login View";
        }
    }

    // Check which tab is currently selected
    NSString *currentlySelectedScreen = @"";
    switch (self.tabBarController.selectedIndex) {
        case kReaderTabIndex:
            currentlySelectedScreen = @"Reader";
            break;
        case kNotificationsTabIndex:
            currentlySelectedScreen = @"Notifications";
            break;
        case kMeTabIndex:
            currentlySelectedScreen = @"Blog List";
            break;
        default:
            break;
    }

    return currentlySelectedScreen;
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
    DDLogInfo(@"%@ %@", self, NSStringFromSelector(_cmd));
}

- (void)applicationWillResignActive:(UIApplication *)application
{
    DDLogInfo(@"%@ %@", self, NSStringFromSelector(_cmd));
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
    DDLogInfo(@"%@ %@", self, NSStringFromSelector(_cmd));
    [WPAnalytics track:WPAnalyticsStatApplicationOpened];
}

- (BOOL)application:(UIApplication *)application shouldSaveApplicationState:(NSCoder *)coder
{
    return YES;
}

- (BOOL)application:(UIApplication *)application shouldRestoreApplicationState:(NSCoder *)coder
{
    return YES;
}

#pragma mark - Push Notification delegate

- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken
{
    [NotificationsManager registerDeviceToken:deviceToken];
}

- (void)application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error
{
    [NotificationsManager registrationDidFail:error];
}

- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo
{
    DDLogMethod();

    [NotificationsManager handleNotification:userInfo forState:application.applicationState completionHandler:nil];
}

- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler
{
    DDLogMethod();

    [NotificationsManager handleNotification:userInfo forState:[UIApplication sharedApplication].applicationState completionHandler:completionHandler];
}

- (void)application:(UIApplication *)application handleActionWithIdentifier:(NSString *)identifier
                                        forRemoteNotification:(NSDictionary *)remoteNotification
                                            completionHandler:(void (^)())completionHandler
{
    [NotificationsManager handleActionWithIdentifier:identifier forRemoteNotification:remoteNotification];
    
    completionHandler();
}

#pragma mark - OpenURL helpers

/**
 *  @brief      Handle the a new post request by URL.
 *  
 *  @param      url     The URL with the request info.  Cannot be nil.
 *
 *  @return     YES if the request was handled, NO otherwise.
 */
- (BOOL)handleNewPostRequestWithURL:(NSURL*)url
{
    NSParameterAssert([url isKindOfClass:[NSURL class]]);
    
    BOOL handled = NO;
    
    // Create a new post from data shared by a third party application.
    NSDictionary *params = [[url query] dictionaryFromQueryString];
    DDLogInfo(@"App launched for new post with params: %@", params);
    
    params = [self sanitizeNewPostParameters:params];
    
    if ([params count]) {
        [self showPostTabWithOptions:params];
        handled = YES;
    }
	
    return handled;
}

/**
 *	@brief		Sanitizes a 'new post' parameters dictionary.
 *	@details	Prevent HTML injections like the one in:
 *				https://github.com/wordpress-mobile/WordPress-iOS-Editor/issues/211
 *
 *	@param		parameters		The new post parameters to sanitize.  Cannot be nil.
 *
 *  @returns    The sanitized dictionary.
 */
- (NSDictionary*)sanitizeNewPostParameters:(NSDictionary*)parameters
{
    NSParameterAssert([parameters isKindOfClass:[NSDictionary class]]);
	
    NSUInteger parametersCount = [parameters count];
    
    NSMutableDictionary* sanitizedDictionary = [[NSMutableDictionary alloc] initWithCapacity:parametersCount];
    
    for (NSString* key in [parameters allKeys])
    {
        NSString* value = [parameters objectForKey:key];
        
        if ([key isEqualToString:kWPNewPostURLParamContentKey]) {
            value = [value stringByStrippingHTML];
        } else if ([key isEqualToString:kWPNewPostURLParamTagsKey]) {
            value = [value stringByStrippingHTML];
        }
        
        [sanitizedDictionary setObject:value forKey:key];
    }
    
    return [NSDictionary dictionaryWithDictionary:sanitizedDictionary];
}

#pragma mark - Custom methods

- (void)showWelcomeScreenIfNeededAnimated:(BOOL)animated
{
    if ([self noBlogsAndNoWordPressDotComAccount]) {
        UIViewController *presenter = self.window.rootViewController;
        if (presenter.presentedViewController) {
            [presenter dismissViewControllerAnimated:NO completion:nil];
        }

        [self showWelcomeScreenAnimated:animated thenEditor:NO];
    }
}

- (void)showWelcomeScreenAnimated:(BOOL)animated thenEditor:(BOOL)thenEditor
{
    LoginViewController *loginViewController = [[LoginViewController alloc] init];
    if (thenEditor) {
        loginViewController.dismissBlock = ^{
            [self.window.rootViewController dismissViewControllerAnimated:YES completion:nil];
        };
        loginViewController.showEditorAfterAddingSites = YES;
    }

    UINavigationController *navigationController = [[UINavigationController alloc] initWithRootViewController:loginViewController];
    navigationController.navigationBar.translucent = NO;

    [self.window.rootViewController presentViewController:navigationController animated:animated completion:nil];
}

- (BOOL)noBlogsAndNoWordPressDotComAccount
{
    NSManagedObjectContext *context = [[ContextManager sharedInstance] mainContext];
    AccountService *accountService = [[AccountService alloc] initWithManagedObjectContext:context];
    BlogService *blogService = [[BlogService alloc] initWithManagedObjectContext:context];
    WPAccount *defaultAccount = [accountService defaultWordPressComAccount];

    NSInteger blogCount = [blogService blogCountSelfHosted];
    return blogCount == 0 && !defaultAccount;
}

- (void)customizeAppearance
{
    UIColor *defaultTintColor = self.window.tintColor;
    self.window.tintColor = [WPStyleGuide wordPressBlue];

    [[UINavigationBar appearance] setBarTintColor:[WPStyleGuide wordPressBlue]];
    [[UINavigationBar appearance] setTintColor:[UIColor whiteColor]];
    [[UINavigationBar appearanceWhenContainedIn:[MFMailComposeViewController class], nil] setBarTintColor:[UIColor whiteColor]];
    [[UINavigationBar appearanceWhenContainedIn:[MFMailComposeViewController class], nil] setTintColor:defaultTintColor];

    [[UITabBar appearance] setShadowImage:[UIImage imageWithColor:[UIColor colorWithRed:210.0/255.0 green:222.0/255.0 blue:230.0/255.0 alpha:1.0]]];
    [[UITabBar appearance] setTintColor:[WPStyleGuide newKidOnTheBlockBlue]];

    [[UINavigationBar appearance] setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor whiteColor], NSFontAttributeName: [WPFontManager openSansBoldFontOfSize:16.0]} ];
// temporarily removed to fix transparent UINavigationBar within Helpshift
//    [[UINavigationBar appearance] setBackgroundImage:[UIImage imageNamed:@"transparent-point"] forBarMetrics:UIBarMetricsDefault];
//    [[UINavigationBar appearance] setShadowImage:[UIImage imageNamed:@"transparent-point"]];
    [[UIBarButtonItem appearance] setTitleTextAttributes:@{NSFontAttributeName: [WPStyleGuide regularTextFont], NSForegroundColorAttributeName: [UIColor whiteColor]} forState:UIControlStateNormal];
    [[UIBarButtonItem appearance] setTitleTextAttributes:@{NSFontAttributeName: [WPStyleGuide regularTextFont], NSForegroundColorAttributeName: [UIColor lightGrayColor]} forState:UIControlStateDisabled];
    [[UIToolbar appearance] setBarTintColor:[WPStyleGuide wordPressBlue]];
    [[UISwitch appearance] setOnTintColor:[WPStyleGuide wordPressBlue]];
    [[UIApplication sharedApplication] setStatusBarStyle:UIStatusBarStyleLightContent];
    [[UITabBarItem appearance] setTitleTextAttributes:@{NSFontAttributeName: [WPFontManager openSansRegularFontOfSize:10.0]} forState:UIControlStateNormal];

    [[UINavigationBar appearanceWhenContainedIn:[UIReferenceLibraryViewController class], nil] setBackgroundImage:nil forBarMetrics:UIBarMetricsDefault];
    [[UINavigationBar appearanceWhenContainedIn:[UIReferenceLibraryViewController class], nil] setBarTintColor:[WPStyleGuide wordPressBlue]];
    [[UIToolbar appearanceWhenContainedIn:[UIReferenceLibraryViewController class], nil] setBarTintColor:[UIColor darkGrayColor]];
    
    [[UIToolbar appearanceWhenContainedIn:[WPEditorViewController class], nil] setBarTintColor:[UIColor whiteColor]];
}

#pragma mark - Tab bar methods

- (UITabBarController *)tabBarController
{
    if (_tabBarController) {
        return _tabBarController;
    }

    UIOffset tabBarTitleOffset = UIOffsetMake(0, 0);
    if ( IS_IPHONE ) {
        tabBarTitleOffset = UIOffsetMake(0, -2);
    }
    _tabBarController = [[UITabBarController alloc] init];
    _tabBarController.delegate = self;
    _tabBarController.restorationIdentifier = WPTabBarRestorationID;
    [_tabBarController.tabBar setTranslucent:NO];

    // Create a background
    // (not strictly needed when white, but left here for possible customization)
    _tabBarController.tabBar.backgroundImage = [UIImage imageWithColor:[UIColor whiteColor]];

    self.readerPostsViewController = [[ReaderPostsViewController alloc] init];
    UINavigationController *readerNavigationController = [[UINavigationController alloc] initWithRootViewController:self.readerPostsViewController];
    readerNavigationController.navigationBar.translucent = NO;
    readerNavigationController.tabBarItem.image = [UIImage imageNamed:@"icon-tab-reader"];
    readerNavigationController.tabBarItem.selectedImage = [UIImage imageNamed:@"icon-tab-reader-filled"];
    readerNavigationController.restorationIdentifier = WPReaderNavigationRestorationID;
    self.readerPostsViewController.title = NSLocalizedString(@"Reader", nil);
    [readerNavigationController.tabBarItem setTitlePositionAdjustment:tabBarTitleOffset];
    
    UIStoryboard *notificationsStoryboard = [UIStoryboard storyboardWithName:@"Notifications" bundle:nil];
    self.notificationsViewController = [notificationsStoryboard instantiateInitialViewController];
    UINavigationController *notificationsNavigationController = [[UINavigationController alloc] initWithRootViewController:self.notificationsViewController];
    notificationsNavigationController.navigationBar.translucent = NO;
    notificationsNavigationController.tabBarItem.image = [UIImage imageNamed:@"icon-tab-notifications"];
    notificationsNavigationController.tabBarItem.selectedImage = [UIImage imageNamed:@"icon-tab-notifications-filled"];
    notificationsNavigationController.restorationIdentifier = WPNotificationsNavigationRestorationID;
    self.notificationsViewController.title = NSLocalizedString(@"Notifications", @"");
    [notificationsNavigationController.tabBarItem setTitlePositionAdjustment:tabBarTitleOffset];

    self.blogListViewController = [[BlogListViewController alloc] init];
    UINavigationController *blogListNavigationController = [[UINavigationController alloc] initWithRootViewController:self.blogListViewController];
    blogListNavigationController.navigationBar.translucent = NO;
    blogListNavigationController.tabBarItem.image = [UIImage imageNamed:@"icon-tab-blogs"];
    blogListNavigationController.tabBarItem.selectedImage = [UIImage imageNamed:@"icon-tab-blogs-filled"];
    blogListNavigationController.restorationIdentifier = WPBlogListNavigationRestorationID;
    self.blogListViewController.title = NSLocalizedString(@"Me", @"");
    [blogListNavigationController.tabBarItem setTitlePositionAdjustment:tabBarTitleOffset];

    UIImage *image = [UIImage imageNamed:@"icon-tab-newpost"];
    image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    UIViewController *postsViewController = [[UIViewController alloc] init];
    postsViewController.tabBarItem.image = image;
    postsViewController.tabBarItem.imageInsets = UIEdgeInsetsMake(5.0, 0, -5, 0);
    if (IS_IPAD) {
        postsViewController.tabBarItem.imageInsets = UIEdgeInsetsMake(7.0, 0, -7, 0);
    }

    /*
     If title is used, the title will be visible. See #1158
     If accessibilityLabel/Value are used, the "New Post" text is not read by VoiceOver

     The only apparent solution is to have an actual title, and then move it out of view
     non-VoiceOver users.
     */
    postsViewController.title = NSLocalizedString(@"New Post", @"The accessibility value of the post tab.");
    postsViewController.tabBarItem.titlePositionAdjustment = UIOffsetMake(0, 20.0);

    _tabBarController.viewControllers = @[readerNavigationController, notificationsNavigationController, blogListNavigationController, postsViewController];

    [_tabBarController setSelectedViewController:readerNavigationController];

    return _tabBarController;
}

- (void)showTabForIndex:(NSInteger)tabIndex
{
    [self.tabBarController setSelectedIndex:tabIndex];
}

- (void)showPostTab
{
    [self showPostTabWithOptions:nil];
}

- (void)showPostTabWithOptions:(NSDictionary *)options
{
    UIViewController *presenter = self.window.rootViewController;
    if (presenter.presentedViewController) {
        [presenter dismissViewControllerAnimated:NO completion:nil];
    }

    UINavigationController *navController;
    if ([WPPostViewController isNewEditorEnabled]) {
        WPPostViewController *editPostViewController;
        if (!options) {
            [WPAnalytics track:WPAnalyticsStatEditorCreatedPost withProperties:@{ @"tap_source": @"tab_bar" }];
            editPostViewController = [[WPPostViewController alloc] initWithDraftForLastUsedBlog];
        } else {
            editPostViewController = [[WPPostViewController alloc] initWithTitle:[options stringForKey:kWPNewPostURLParamTitleKey]
                                                                      andContent:[options stringForKey:kWPNewPostURLParamContentKey]
                                                                         andTags:[options stringForKey:kWPNewPostURLParamTagsKey]
                                                                        andImage:[options stringForKey:kWPNewPostURLParamImageKey]];
        }
        navController = [[UINavigationController alloc] initWithRootViewController:editPostViewController];
        navController.restorationIdentifier = WPEditorNavigationRestorationID;
        navController.restorationClass = [WPPostViewController class];
    } else {
        WPLegacyEditPostViewController *editPostLegacyViewController;
        if (!options) {
            [WPAnalytics track:WPAnalyticsStatEditorCreatedPost withProperties:@{ @"tap_source": @"tab_bar" }];
            editPostLegacyViewController = [[WPLegacyEditPostViewController alloc] initWithDraftForLastUsedBlog];
        } else {
            editPostLegacyViewController = [[WPLegacyEditPostViewController alloc] initWithTitle:[options stringForKey:kWPNewPostURLParamTitleKey]
                                                                      andContent:[options stringForKey:kWPNewPostURLParamContentKey]
                                                                         andTags:[options stringForKey:kWPNewPostURLParamTagsKey]
                                                                        andImage:[options stringForKey:kWPNewPostURLParamImageKey]];
        }
        navController = [[UINavigationController alloc] initWithRootViewController:editPostLegacyViewController];
        navController.restorationIdentifier = WPLegacyEditorNavigationRestorationID;
        navController.restorationClass = [WPLegacyEditPostViewController class];
    }
        
    navController.modalPresentationStyle = UIModalPresentationCurrentContext;
    navController.navigationBar.translucent = NO;
    [navController setToolbarHidden:NO]; // Make the toolbar visible here to avoid a weird left/right transition when the VC appears.
    [self.window.rootViewController presentViewController:navController animated:YES completion:nil];
}

- (void)switchTabToPostsListForPost:(AbstractPost *)post
{
    // Make sure the desired tab is selected.
    [self showTabForIndex:kMeTabIndex];

    // Check which VC is showing.
    UINavigationController *blogListNavController = [self.tabBarController.viewControllers objectAtIndex:kMeTabIndex];
    UIViewController *topVC = blogListNavController.topViewController;
    if ([topVC isKindOfClass:[PostsViewController class]]) {
        Blog *blog = ((PostsViewController *)topVC).blog;
        if ([post.blog.objectID isEqual:blog.objectID]) {
            // The desired post view controller is already the top viewController for the tab.
            // Nothing to see here.  Move along.
            return;
        }
    }

    // Build and set the navigation heirarchy for the Me tab.
    BlogListViewController *blogListViewController = [blogListNavController.viewControllers objectAtIndex:0];

    BlogDetailsViewController *blogDetailsViewController = [[BlogDetailsViewController alloc] init];
    blogDetailsViewController.blog = post.blog;

    PostsViewController *postsViewController = [[PostsViewController alloc] init];
    [postsViewController setBlog:post.blog];

    [blogListNavController setViewControllers:@[blogListViewController, blogDetailsViewController, postsViewController]];
}

- (BOOL)isNavigatingMeTab
{
    return (self.tabBarController.selectedIndex == kMeTabIndex && [self.blogListViewController.navigationController.viewControllers count] > 1);
}

#pragma mark - UITabBarControllerDelegate methods.

- (BOOL)tabBarController:(UITabBarController *)tabBarController shouldSelectViewController:(UIViewController *)viewController
{
    if ([tabBarController.viewControllers indexOfObject:viewController] == 3) {
        NSManagedObjectContext *context = [[ContextManager sharedInstance] mainContext];
        BlogService *blogService = [[BlogService alloc] initWithManagedObjectContext:context];

        // Ignore taps on the post tab and instead show the modal.
        if ([blogService blogCountVisibleForAllAccounts] == 0) {
            [self showWelcomeScreenAnimated:YES thenEditor:YES];
        } else {
            [self showPostTab];
        }
        return NO;
    } else if ([tabBarController.viewControllers indexOfObject:viewController] == 2) {
        // If the user has one blog then we don't want to present them with the main "me"
        // screen where they can see all their blogs. In the case of only one blog just show
        // the main blog details screen

        // Don't kick of this auto selecting behavior if the user taps the the active tab as it
        // would break from standard iOS UX
        if (tabBarController.selectedIndex != 2) {
            UINavigationController *navController = (UINavigationController *)viewController;
            BlogListViewController *blogListViewController = (BlogListViewController *)navController.viewControllers[0];
            if ([blogListViewController shouldBypassBlogListViewControllerWhenSelectedFromTabBar]) {
                if ([navController.visibleViewController isKindOfClass:[blogListViewController class]]) {
                    [blogListViewController bypassBlogListViewController];
                }
            }
        }
    }

    // If the current view controller is selected already and it's at its root then scroll to the top
    if (tabBarController.selectedViewController == viewController) {
        if ([viewController isKindOfClass:[UINavigationController class]]) {
            UINavigationController *navController = (UINavigationController *)viewController;
            if (navController.topViewController == navController.viewControllers.firstObject &&
                [navController.topViewController.view isKindOfClass:[UITableView class]]) {
                
                UITableView *tableView = (UITableView *)[[navController topViewController] view];
                CGPoint topOffset = CGPointMake(0.0f, -tableView.contentInset.top);
                [tableView setContentOffset:topOffset animated:YES];
            }
        }
    }

    return YES;
}

#pragma mark - Application directories

- (void)changeCurrentDirectory
{
    // Set current directory for WordPress app
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *currentDirectoryPath = [[paths objectAtIndex:0] stringByAppendingPathComponent:@"wordpress"];

    BOOL isDir;
    if (![fileManager fileExistsAtPath:currentDirectoryPath isDirectory:&isDir] || !isDir) {
        [fileManager createDirectoryAtPath:currentDirectoryPath withIntermediateDirectories:YES attributes:nil error:nil];
    }
    [fileManager changeCurrentDirectoryPath:currentDirectoryPath];
}

#pragma mark - Notifications

- (void)defaultAccountDidChange:(NSNotification *)notification
{
    NSManagedObjectContext *context = [[ContextManager sharedInstance] mainContext];
    AccountService *accountService = [[AccountService alloc] initWithManagedObjectContext:context];
    WPAccount *defaultAccount = [accountService defaultWordPressComAccount];

    [Crashlytics setUserName:[defaultAccount username]];
    [self setCommonCrashlyticsParameters];
}

#pragma mark - Crash reporting

- (void)configureCrashlytics
{
#if DEBUG
    return;
#endif
#ifdef INTERNAL_BUILD
    return;
#endif

    if ([[WordPressComApiCredentials crashlyticsApiKey] length] == 0) {
        return;
    }

    [Crashlytics startWithAPIKey:[WordPressComApiCredentials crashlyticsApiKey]];
    [[Crashlytics sharedInstance] setDelegate:self];

    NSManagedObjectContext *context = [[ContextManager sharedInstance] mainContext];
    AccountService *accountService = [[AccountService alloc] initWithManagedObjectContext:context];
    WPAccount *defaultAccount = [accountService defaultWordPressComAccount];

    BOOL hasCredentials = (defaultAccount != nil);
    [self setCommonCrashlyticsParameters];

    if (hasCredentials && [defaultAccount username] != nil) {
        [Crashlytics setUserName:[defaultAccount username]];
    }

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(defaultAccountDidChange:) name:WPAccountDefaultWordPressComAccountChangedNotification object:nil];
}

- (void)crashlytics:(Crashlytics *)crashlytics didDetectCrashDuringPreviousExecution:(id<CLSCrashReport>)crash
{
    DDLogMethod();
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSInteger crashCount = [defaults integerForKey:@"crashCount"];
    crashCount += 1;
    [defaults setInteger:crashCount forKey:@"crashCount"];
    [defaults synchronize];
}

- (void)setCommonCrashlyticsParameters
{
    NSManagedObjectContext *context = [[ContextManager sharedInstance] mainContext];
    AccountService *accountService = [[AccountService alloc] initWithManagedObjectContext:context];
    BlogService *blogService = [[BlogService alloc] initWithManagedObjectContext:context];
    WPAccount *defaultAccount = [accountService defaultWordPressComAccount];

    BOOL loggedIn = defaultAccount != nil;
    [Crashlytics setObjectValue:@(loggedIn) forKey:@"logged_in"];
    [Crashlytics setObjectValue:@(loggedIn) forKey:@"connected_to_dotcom"];
    [Crashlytics setObjectValue:@([blogService blogCountForAllAccounts]) forKey:@"number_of_blogs"];
}

- (void)configureHockeySDK
{
#ifndef INTERNAL_BUILD
    return;
#endif
    [[BITHockeyManager sharedHockeyManager] configureWithIdentifier:[WordPressComApiCredentials hockeyappAppId]
                                                           delegate:self];
    [[BITHockeyManager sharedHockeyManager].authenticator setIdentificationType:BITAuthenticatorIdentificationTypeDevice];
    [[BITHockeyManager sharedHockeyManager] startManager];
    [[BITHockeyManager sharedHockeyManager].authenticator authenticateInstallation];
}

#pragma mark - BITCrashManagerDelegate

- (NSString *)applicationLogForCrashManager:(BITCrashManager *)crashManager
{
    NSString *description = [self getLogFilesContentWithMaxSize:5000]; // 5000 bytes should be enough!
    if ([description length] == 0) {
        return nil;
    }

    return description;
}

#pragma mark - Media cleanup

- (void)cleanUnusedMediaFileFromTmpDir
{
    DDLogInfo(@"%@ %@", self, NSStringFromSelector(_cmd));
    
    NSManagedObjectContext *context = [[ContextManager sharedInstance] newDerivedContext];
    [context performBlock:^{

        // Fetch Media URL's and return them as Dictionary Results:
        // This way we'll avoid any CoreData Faulting Exception due to deletions performed on another context
        NSString *localUrlProperty      = NSStringFromSelector(@selector(localURL));

        NSFetchRequest *fetchRequest    = [[NSFetchRequest alloc] init];
        fetchRequest.entity             = [NSEntityDescription entityForName:NSStringFromClass([Media class]) inManagedObjectContext:context];
        fetchRequest.predicate          = [NSPredicate predicateWithFormat:@"ANY posts.blog != NULL AND remoteStatusNumber <> %@", @(MediaRemoteStatusSync)];

        fetchRequest.propertiesToFetch  = @[ localUrlProperty ];
        fetchRequest.resultType         = NSDictionaryResultType;

        NSError *error = nil;
        NSArray *mediaObjectsToKeep     = [context executeFetchRequest:fetchRequest error:&error];

        if (error) {
            DDLogError(@"Error cleaning up tmp files: %@", error.localizedDescription);
            return;
        }

        // Get a references to media files linked in a post
        DDLogInfo(@"%i media items to check for cleanup", mediaObjectsToKeep.count);

        NSMutableSet *pathsToKeep       = [NSMutableSet set];
        for (NSDictionary *mediaDict in mediaObjectsToKeep) {
            NSString *path = mediaDict[localUrlProperty];
            if (path) {
                [pathsToKeep addObject:path];
            }
        }

        // Search for [JPG || JPEG || PNG || GIF] files within the Documents Folder
        NSString *documentsDirectory    = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSArray *contentsOfDir          = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:documentsDirectory error:nil];

        NSSet *mediaExtensions          = [NSSet setWithObjects:@"jpg", @"jpeg", @"png", @"gif", nil];

        for (NSString *currentPath in contentsOfDir) {
            NSString *extension = currentPath.pathExtension.lowercaseString;
            if (![mediaExtensions containsObject:extension]) {
                continue;
            }

            // If the file is not referenced in any post we can delete it
            NSString *filepath = [documentsDirectory stringByAppendingPathComponent:currentPath];

            if (![pathsToKeep containsObject:filepath]) {
                NSError *nukeError = nil;
                if ([[NSFileManager defaultManager] removeItemAtPath:filepath error:&nukeError] == NO) {
                    DDLogError(@"Error [%@] while nuking Unused Media at path [%@]", nukeError.localizedDescription, filepath);
                }
            }
        }
    }];
}

- (void)setupImageResizeSettings
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    NSString *oldKey = @"media_resize_preference";
    // 4 was the value for "Original"
    if ([defaults integerForKey:oldKey] == 4) {
        [WPImageOptimizer setShouldOptimizeImages:NO];
    }
    [defaults removeObjectForKey:oldKey];
}

#pragma mark - Networking setup, User agents

- (void)setupUserAgent
{
    // Keep a copy of the original userAgent for use with certain webviews in the app.
    UIWebView *webView = [[UIWebView alloc] init];
    NSString *defaultUA = [webView stringByEvaluatingJavaScriptFromString:@"navigator.userAgent"];

    NSString *appVersion = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleVersion"];
    [[NSUserDefaults standardUserDefaults] setObject:appVersion forKey:@"version_preference"];
    NSString *appUA = [NSString stringWithFormat:@"wp-iphone/%@ (%@ %@, %@) Mobile",
                       appVersion,
                       [[UIDevice currentDevice] systemName],
                       [[UIDevice currentDevice] systemVersion],
                       [[UIDevice currentDevice] model]
                       ];
    NSDictionary *dictionary = [[NSDictionary alloc] initWithObjectsAndKeys: appUA, @"UserAgent", defaultUA, @"DefaultUserAgent", appUA, @"AppUserAgent", nil];
    [[NSUserDefaults standardUserDefaults] registerDefaults:dictionary];
}

- (void)useDefaultUserAgent
{
    NSString *ua = [[NSUserDefaults standardUserDefaults] stringForKey:@"DefaultUserAgent"];
    NSDictionary *dictionary = [[NSDictionary alloc] initWithObjectsAndKeys:ua, @"UserAgent", nil];
    // We have to call registerDefaults else the change isn't picked up by UIWebViews.
    [[NSUserDefaults standardUserDefaults] registerDefaults:dictionary];
    DDLogVerbose(@"User-Agent set to: %@", ua);
}

- (void)useAppUserAgent
{
    NSString *ua = [[NSUserDefaults standardUserDefaults] stringForKey:@"AppUserAgent"];
    NSDictionary *dictionary = [[NSDictionary alloc] initWithObjectsAndKeys:ua, @"UserAgent", nil];
    // We have to call registerDefaults else the change isn't picked up by UIWebViews.
    [[NSUserDefaults standardUserDefaults] registerDefaults:dictionary];

    DDLogVerbose(@"User-Agent set to: %@", ua);
}

- (NSString *)applicationUserAgent
{
    return [[NSUserDefaults standardUserDefaults] objectForKey:@"UserAgent"];
}

- (void)setupSingleSignOn
{
    NSManagedObjectContext *context = [[ContextManager sharedInstance] mainContext];
    AccountService *accountService = [[AccountService alloc] initWithManagedObjectContext:context];
    WPAccount *defaultAccount = [accountService defaultWordPressComAccount];

    if ([defaultAccount username]) {
        [[WPComOAuthController sharedController] setWordPressComUsername:[defaultAccount username]];
        [[WPComOAuthController sharedController] setWordPressComPassword:[defaultAccount password]];
    }
}

- (void)setupReachability
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"
    // Set the wpcom availability to YES to avoid issues with lazy reachibility notifier
    self.wpcomAvailable = YES;
    // Same for general internet connection
    self.connectionAvailable = YES;

    // allocate the internet reachability object
    self.internetReachability = [Reachability reachabilityForInternetConnection];

    // set the blocks
    void (^internetReachabilityBlock)(Reachability *) = ^(Reachability *reach) {
        NSString *wifi = reach.isReachableViaWiFi ? @"Y" : @"N";
        NSString *wwan = reach.isReachableViaWWAN ? @"Y" : @"N";

        DDLogInfo(@"Reachability - Internet - WiFi: %@  WWAN: %@", wifi, wwan);
        self.connectionAvailable = reach.isReachable;
    };
    self.internetReachability.reachableBlock = internetReachabilityBlock;
    self.internetReachability.unreachableBlock = internetReachabilityBlock;

    // start the notifier which will cause the reachability object to retain itself!
    [self.internetReachability startNotifier];
    self.connectionAvailable = [self.internetReachability isReachable];

    // allocate the WP.com reachability object
    self.wpcomReachability = [Reachability reachabilityWithHostname:@"wordpress.com"];

    // set the blocks
    void (^wpcomReachabilityBlock)(Reachability *) = ^(Reachability *reach) {
        NSString *wifi = reach.isReachableViaWiFi ? @"Y" : @"N";
        NSString *wwan = reach.isReachableViaWWAN ? @"Y" : @"N";
        CTTelephonyNetworkInfo *netInfo = [CTTelephonyNetworkInfo new];
        CTCarrier *carrier = [netInfo subscriberCellularProvider];
        NSString *type = nil;
        if ([netInfo respondsToSelector:@selector(currentRadioAccessTechnology)]) {
            type = [netInfo currentRadioAccessTechnology];
        }
        NSString *carrierName = nil;
        if (carrier) {
            carrierName = [NSString stringWithFormat:@"%@ [%@/%@/%@]", carrier.carrierName, [carrier.isoCountryCode uppercaseString], carrier.mobileCountryCode, carrier.mobileNetworkCode];
        }

        DDLogInfo(@"Reachability - WordPress.com - WiFi: %@  WWAN: %@  Carrier: %@  Type: %@", wifi, wwan, carrierName, type);
        self.wpcomAvailable = reach.isReachable;
    };
    self.wpcomReachability.reachableBlock = wpcomReachabilityBlock;
    self.wpcomReachability.unreachableBlock = wpcomReachabilityBlock;

    // start the notifier which will cause the reachability object to retain itself!
    [self.wpcomReachability startNotifier];
#pragma clang diagnostic pop
}

#pragma mark - Simperium

- (void)configureSimperium
{
	ContextManager* manager         = [ContextManager sharedInstance];
    NSDictionary *bucketOverrides   = @{ NSStringFromClass([Notification class]) : @"note20" };
    
    self.simperium = [[Simperium alloc] initWithModel:manager.managedObjectModel
											  context:manager.mainContext
										  coordinator:manager.persistentStoreCoordinator
                                                label:[NSString string]
                                      bucketOverrides:bucketOverrides];

#ifdef DEBUG
	self.simperium.verboseLoggingEnabled = false;
#endif
}

- (void)loginSimperium
{
    NSManagedObjectContext *context = [[ContextManager sharedInstance] mainContext];
    AccountService *accountService  = [[AccountService alloc] initWithManagedObjectContext:context];
    WPAccount *account              = [accountService defaultWordPressComAccount];
    NSString *apiKey                = [WordPressComApiCredentials simperiumAPIKey];

    if (!account.authToken.length || !apiKey.length) {
        return;
    }

    NSString *simperiumToken = [NSString stringWithFormat:@"WPCC/%@/%@", apiKey, account.authToken];
    NSString *simperiumAppID = [WordPressComApiCredentials simperiumAppId];
    [self.simperium authenticateWithAppID:simperiumAppID token:simperiumToken];
}

- (void)logoutSimperiumAndResetNotifications
{
    [self.simperium signOutAndRemoveLocalData:YES completion:nil];
}

#pragma mark - Keychain

+ (void)fixKeychainAccess
{
    NSDictionary *query = @{
                            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                            (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleWhenUnlocked,
                            (__bridge id)kSecReturnAttributes: @YES,
                            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll
                            };

    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess) {
        return;
    }
    DDLogVerbose(@"Fixing keychain items with wrong access requirements");
    for (NSDictionary *item in (__bridge_transfer NSArray *)result) {
        NSDictionary *itemQuery = @{
                                    (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                                    (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleWhenUnlocked,
                                    (__bridge id)kSecAttrService: item[(__bridge id)kSecAttrService],
                                    (__bridge id)kSecAttrAccount: item[(__bridge id)kSecAttrAccount],
                                    (__bridge id)kSecReturnAttributes: @YES,
                                    (__bridge id)kSecReturnData: @YES,
                                    };

        CFTypeRef itemResult = NULL;
        status = SecItemCopyMatching((__bridge CFDictionaryRef)itemQuery, &itemResult);
        if (status == errSecSuccess) {
            NSDictionary *itemDictionary = (__bridge NSDictionary *)itemResult;
            NSDictionary *updateQuery = @{
                                          (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                                          (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleWhenUnlocked,
                                          (__bridge id)kSecAttrService: item[(__bridge id)kSecAttrService],
                                          (__bridge id)kSecAttrAccount: item[(__bridge id)kSecAttrAccount],
                                          };
            NSDictionary *updatedAttributes = @{
                                                (__bridge id)kSecValueData: itemDictionary[(__bridge id)kSecValueData],
                                                (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlock,
                                                };
            status = SecItemUpdate((__bridge CFDictionaryRef)updateQuery, (__bridge CFDictionaryRef)updatedAttributes);
            if (status == errSecSuccess) {
                DDLogInfo(@"Migrated keychain item %@", item);
            } else {
                DDLogError(@"Error migrating keychain item: %d", status);
            }
        } else {
            DDLogError(@"Error migrating keychain item: %d", status);
        }
    }
    DDLogVerbose(@"End keychain fixing");
}

#pragma mark - Debugging and logging

- (void)printDebugLaunchInfoWithLaunchOptions:(NSDictionary *)launchOptions
{
    UIDevice *device = [UIDevice currentDevice];
    NSInteger crashCount = [[NSUserDefaults standardUserDefaults] integerForKey:@"crashCount"];
    NSArray *languages = [[NSUserDefaults standardUserDefaults] objectForKey:@"AppleLanguages"];
    NSString *currentLanguage = [languages objectAtIndex:0];
    BOOL extraDebug = [[NSUserDefaults standardUserDefaults] boolForKey:@"extra_debug"];
    BlogService *blogService = [[BlogService alloc] initWithManagedObjectContext:[[ContextManager sharedInstance] mainContext]];
    NSArray *blogs = [blogService blogsForAllAccounts];

    DDLogInfo(@"===========================================================================");
    DDLogInfo(@"Launching WordPress for iOS %@...", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"]);
    DDLogInfo(@"Crash count:       %d", crashCount);
#ifdef DEBUG
    DDLogInfo(@"Debug mode:  Debug");
#else
    DDLogInfo(@"Debug mode:  Production");
#endif
    DDLogInfo(@"Extra debug: %@", extraDebug ? @"YES" : @"NO");
    DDLogInfo(@"Device model: %@ (%@)", [UIDeviceHardware platformString], [UIDeviceHardware platform]);
    DDLogInfo(@"OS:        %@ %@", [device systemName], [device systemVersion]);
    DDLogInfo(@"Language:  %@", currentLanguage);
    DDLogInfo(@"UDID:      %@", [device wordpressIdentifier]);
    DDLogInfo(@"APN token: %@", [[NSUserDefaults standardUserDefaults] objectForKey:NotificationsDeviceToken]);
    DDLogInfo(@"Launch options: %@", launchOptions);

    if (blogs.count > 0) {
        DDLogInfo(@"All blogs on device:");
        for (Blog *blog in blogs) {
            DDLogInfo(@"Name: %@ URL: %@ XML-RPC: %@ isWpCom: %@ blogId: %@ jetpackAccount: %@", blog.blogName, blog.url, blog.xmlrpc, blog.account.isWpcom ? @"YES" : @"NO", blog.blogID, !!blog.jetpackAccount ? @"PRESENT" : @"NONE");
        }
    } else {
        DDLogInfo(@"No blogs configured on device.");
    }

    DDLogInfo(@"===========================================================================");
}

- (void)removeCredentialsForDebug
{
#if DEBUG
    /*
     A dictionary containing the credentials for all available protection spaces.
     The dictionary has keys corresponding to the NSURLProtectionSpace objects.
     The values for the NSURLProtectionSpace keys consist of dictionaries where the keys are user name strings, and the value is the corresponding NSURLCredential object.
     */
    [[[NSURLCredentialStorage sharedCredentialStorage] allCredentials] enumerateKeysAndObjectsUsingBlock:^(NSURLProtectionSpace *ps, NSDictionary *dict, BOOL *stop) {
        [dict enumerateKeysAndObjectsUsingBlock:^(id key, NSURLCredential *credential, BOOL *stop) {
            DDLogVerbose(@"Removing credential %@ for %@", [credential user], [ps host]);
            [[NSURLCredentialStorage sharedCredentialStorage] removeCredential:credential forProtectionSpace:ps];
        }];
    }];
#endif
}

- (void)configureLogging
{
    // Remove the old Documents/wordpress.log if it exists
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    NSString *filePath = [documentsDirectory stringByAppendingPathComponent:@"wordpress.log"];
    NSFileManager *fileManager = [NSFileManager defaultManager];

    if ([fileManager fileExistsAtPath:filePath]) {
        [fileManager removeItemAtPath:filePath error:nil];
    }

    // Sets up the CocoaLumberjack logging; debug output to console and file
#ifdef DEBUG
    [DDLog addLogger:[DDASLLogger sharedInstance]];
    [DDLog addLogger:[DDTTYLogger sharedInstance]];
#endif

#ifndef INTERNAL_BUILD
    [DDLog addLogger:[CrashlyticsLogger sharedInstance]];
#endif

    [DDLog addLogger:self.fileLogger];

    BOOL extraDebug = [[NSUserDefaults standardUserDefaults] boolForKey:@"extra_debug"];
    if (extraDebug) {
        ddLogLevel = LOG_LEVEL_VERBOSE;
    }
}

- (DDFileLogger *)fileLogger
{
    if (_fileLogger) {
        return _fileLogger;
    }
    _fileLogger = [[DDFileLogger alloc] init];
    _fileLogger.rollingFrequency = 60 * 60 * 24; // 24 hour rolling
    _fileLogger.logFileManager.maximumNumberOfLogFiles = 7;

    return _fileLogger;
}

// get the log content with a maximum byte size
- (NSString *)getLogFilesContentWithMaxSize:(NSInteger)maxSize
{
    NSMutableString *description = [NSMutableString string];

    NSArray *sortedLogFileInfos = [[self.fileLogger logFileManager] sortedLogFileInfos];
    NSInteger count = [sortedLogFileInfos count];

    // we start from the last one
    for (NSInteger index = 0; index < count; index++) {
        DDLogFileInfo *logFileInfo = [sortedLogFileInfos objectAtIndex:index];

        NSData *logData = [[NSFileManager defaultManager] contentsAtPath:[logFileInfo filePath]];
        if ([logData length] > 0) {
            NSString *result = [[NSString alloc] initWithBytes:[logData bytes]
                                                        length:[logData length]
                                                      encoding: NSUTF8StringEncoding];

            [description appendString:result];
        }
    }

    if ([description length] > maxSize) {
        description = (NSMutableString *)[description substringWithRange:NSMakeRange(0, maxSize)];
    }

    return description;
}

- (void)toggleExtraDebuggingIfNeeded
{
    if (!_listeningForBlogChanges) {
        _listeningForBlogChanges = YES;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleDefaultAccountChangedNotification:) name:WPAccountDefaultWordPressComAccountChangedNotification object:nil];
    }

    if ([self noBlogsAndNoWordPressDotComAccount]) {
        // When there are no blogs in the app the settings screen is unavailable.
        // In this case, enable extra_debugging by default to help troubleshoot any issues.
        if ([[NSUserDefaults standardUserDefaults] objectForKey:@"orig_extra_debug"] != nil) {
            return; // Already saved. Don't save again or we could loose the original value.
        }

        NSString *origExtraDebug = [[NSUserDefaults standardUserDefaults] boolForKey:@"extra_debug"] ? @"YES" : @"NO";
        [[NSUserDefaults standardUserDefaults] setObject:origExtraDebug forKey:@"orig_extra_debug"];
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"extra_debug"];
        ddLogLevel = LOG_LEVEL_VERBOSE;
        [NSUserDefaults resetStandardUserDefaults];
    } else {
        NSString *origExtraDebug = [[NSUserDefaults standardUserDefaults] stringForKey:@"orig_extra_debug"];
        if (origExtraDebug == nil) {
            return;
        }

        // Restore the original setting and remove orig_extra_debug.
        [[NSUserDefaults standardUserDefaults] setBool:[origExtraDebug boolValue] forKey:@"extra_debug"];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"orig_extra_debug"];
        [NSUserDefaults resetStandardUserDefaults];

        if ([origExtraDebug boolValue]) {
            ddLogLevel = LOG_LEVEL_VERBOSE;
        }
    }
}

#pragma mark - Notifications

- (void)handleDefaultAccountChangedNotification:(NSNotification *)notification
{
    [self toggleExtraDebuggingIfNeeded];

    // If the notification object is not nil, then it's a login
    if (notification.object) {
        [self loginSimperium];

        NSManagedObjectContext *context     = [[ContextManager sharedInstance] newDerivedContext];
        ReaderTopicService *topicService    = [[ReaderTopicService alloc] initWithManagedObjectContext:context];
        [context performBlock:^{
            ReaderTopic *topic              = topicService.currentTopic;
            if (topic) {
                ReaderPostService *service  = [[ReaderPostService alloc] initWithManagedObjectContext:context];
                [service fetchPostsForTopic:topic success:nil failure:nil];
            }
        }];
    } else {
        // No need to check for welcome screen unless we are signing out
        [self logoutSimperiumAndResetNotifications];
        [self showWelcomeScreenIfNeededAnimated:NO];
    }
}

#pragma mark - GUI animations

- (void)showVisualEditorAvailableInSettingsAnimation:(BOOL)available
{
	UIView* notificationView = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
	notificationView.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.5f];
	notificationView.alpha = 0.0f;
	
	[self.window addSubview:notificationView];
	
	[UIView animateWithDuration:0.2f animations:^{
		notificationView.alpha = 1.0f;
	} completion:^(BOOL finished) {
		
		NSString* statusString = nil;
		
		if (available) {
			statusString = NSLocalizedString(@"Visual Editor added to Settings", nil);
		} else {
			statusString = NSLocalizedString(@"Visual Editor removed from Settings", nil);
		}
		
		[SVProgressHUD showSuccessWithStatus:statusString];
		
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			[UIView animateWithDuration:0.2f animations:^{
				notificationView.alpha = 0.0f;
			} completion:^(BOOL finished) {
				[notificationView removeFromSuperview];
			}];
		});
	}];
}

@end
