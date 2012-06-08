//
//  WPTableViewControllerSubclass.h
//  WordPress
//
//  Created by Jorge Bernal on 6/8/12.
//  Copyright (c) 2012 WordPress. All rights reserved.
//

#import "WPTableViewController.h"

@interface WPTableViewController (SubclassMethods)
/**
 The results controller is made available to the subclasses so they can access the data
 */
@property (nonatomic,readonly,retain) NSFetchedResultsController *resultsController;

/**
 Sync content with the server
 
 Subclasses can call this method if they need to invoke a refresh, but it's not meant to be implemented by subclasses.
 Override syncItemsWithUserInteraction:success:failure: instead
 
 @param userInteraction Pass YES if the sync is generated by user action
 */
- (void)syncItemsWithUserInteraction:(BOOL)userInteraction;

/// ----------------------------------------------
/// @name Methods that subclasses should implement
/// ----------------------------------------------

/**
 Core Data entity name used by NSFetchedResultsController
 
 e.g. Post, Page, Comment, ...
 
 Subclasses *MUST* implement this method
 */
- (NSString *)entityName;

/**
 When this content was last synced.
 
 @return a NSDate object, or nil if it's never been synced before
 */
- (NSDate *)lastSyncDate;

/**
 Custom fetch request for NSFetchedResultsController
 
 Optional. Only needed if there are custom sort descriptors or predicate
 */
- (NSFetchRequest *)fetchRequest;

/**
 The attribute name to use to group results into sections
 
 @see [NSFetchedResultsController initWithFetchRequest:managedObjectContext:sectionNameKeyPath:cacheName:] for more info on sectionNameKeyPath
 */
- (NSString *)sectionNameKeyPath;

/**
 Returns a new (unconfigured) cell for the table view.
 
 Optional. If a subclass doesn't implement this method, a UITableViewCell with the default style is used
 
 @return a new initialized cell ready to be configured
 */
- (UITableViewCell *)newCell;

/**
 Configure a table cell for a specific index path
 
 Subclasses *MUST* implement this method
 */
- (void)configureCell:(UITableViewCell *)cell atIndexPath:(NSIndexPath *)indexPath;

/**
 Performs syncing of items
 
 Subclasses *MUST* implement this method
 
 @param userInteraction true if the sync responds to a user action, like pull to refresh
 @param success A block that's executed if the sync was successful
 @param failure A block that's executed if there was any error
 */
- (void)syncItemsWithUserInteraction:(BOOL)userInteraction success:(void (^)())success failure:(void (^)(NSError *error))failure;

/**
 Returns a boolean indicating if the blog is syncing that type of item right now
 */
- (BOOL)isSyncing;

/**
 If the subclass supports infinite scrolling, and there's more content available, return YES.
 This is an optional method which returns NO by default
 
 @return YES if there is more content to load
 */
- (BOOL)hasMoreContent;

/**
 Load extra content for infinite scrolling
 */
- (void)loadMoreContent;

@end
