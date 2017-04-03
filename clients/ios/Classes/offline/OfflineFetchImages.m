//
//  OfflineFetchImages.m
//  NewsBlur
//
//  Created by Samuel Clay on 7/15/13.
//  Copyright (c) 2013 NewsBlur. All rights reserved.
//

#import "OfflineFetchImages.h"
#import "NewsBlurAppDelegate.h"
#import "NewsBlurViewController.h"
#import "FMDatabase.h"
#import "FMDatabaseAdditions.h"
#import "Utilities.h"

@implementation OfflineFetchImages
@synthesize appDelegate;

- (void)main {
    appDelegate = [NewsBlurAppDelegate sharedAppDelegate];

    while (YES) {
        BOOL fetched = [self fetchImages];
        if (!fetched) break;
    }
}

- (BOOL)fetchImages {
    if (self.isCancelled) {
        NSLog(@"Images cancelled.");
        return NO;
    }

//    NSLog(@"Fetching images...");
    NSArray *urls = [self uncachedImageUrls];
    
    if (![[[NSUserDefaults standardUserDefaults]
           objectForKey:@"offline_image_download"] boolValue] ||
        ![[[NSUserDefaults standardUserDefaults]
           objectForKey:@"offline_allowed"] boolValue] ||
        [urls count] == 0) {
        NSLog(@"Finished caching images. %ld total", (long)appDelegate.totalUncachedImagesCount);
        dispatch_async(dispatch_get_main_queue(), ^{
            [appDelegate.feedsViewController showDoneNotifier];
            [appDelegate.feedsViewController hideNotifier];
            [appDelegate cleanImageCache];
            [appDelegate finishBackground];
        });
        return NO;
    }

    if (![appDelegate isReachableForOffline]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [appDelegate.feedsViewController showDoneNotifier];
            [appDelegate.feedsViewController hideNotifier];
        });
        return NO;
    }

    
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    [manager.requestSerializer setTimeoutInterval:5];
    manager.responseSerializer = [AFImageResponseSerializer serializer];
    dispatch_group_t group = dispatch_group_create();
    
    for (NSArray *urlArray in urls) {
        NSString *urlString = [urlArray objectAtIndex:0];
        NSString *storyHash = [urlArray objectAtIndex:1];
        NSString *storyTimestamp = [urlArray objectAtIndex:2];
        dispatch_group_enter(group);
        [appDelegate.networkManager GET:urlString parameters:nil progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
            UIImage *image = (UIImage *)responseObject;
            [self storeCachedImage:urlString withImage:image storyHash:storyHash storyTimestamp:storyTimestamp];
            dispatch_group_leave(group);
        } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
            [self storeFailedImage:storyHash];
            dispatch_group_leave(group);
        }];
    }
    dispatch_group_notify(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW,
                                                           (unsigned long)NULL), ^{
        [self cachedImageQueueFinished];
    });
    [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
    
    //    dispatch_async(dispatch_get_main_queue(), ^{
    //        [appDelegate.feedsViewController hideNotifier];
    //    });
    return YES;
}

- (NSArray *)uncachedImageUrls {
    NSMutableArray *urls = [NSMutableArray array];
    
    [appDelegate.database inDatabase:^(FMDatabase *db) {
        NSString *commonQuery = @"FROM cached_images c "
        "INNER JOIN unread_hashes u ON (c.story_hash = u.story_hash) "
        "WHERE c.image_cached is null ";
        int count = [db intForQuery:[NSString stringWithFormat:@"SELECT COUNT(1) %@", commonQuery]];
        if (appDelegate.totalUncachedImagesCount == 0) {
            appDelegate.totalUncachedImagesCount = count;
            appDelegate.remainingUncachedImagesCount = appDelegate.totalUncachedImagesCount;
        } else {
            appDelegate.remainingUncachedImagesCount = count;
        }
        
        int limit = 120;
        NSString *order;
        if ([[[NSUserDefaults standardUserDefaults] objectForKey:@"default_order"] isEqualToString:@"oldest"]) {
            order = @"ASC";
        } else {
            order = @"DESC";
        }
        NSString *sql = [NSString stringWithFormat:@"SELECT c.image_url, c.story_hash, u.story_timestamp %@ ORDER BY u.story_timestamp %@ LIMIT %d", commonQuery, order, limit];
        FMResultSet *cursor = [db executeQuery:sql];
        
        while ([cursor next]) {
            [urls addObject:@[[cursor objectForColumnName:@"image_url"],
             [cursor objectForColumnName:@"story_hash"],
             [cursor objectForColumnName:@"story_timestamp"]]];
        }
        
        [cursor close];
        [self updateProgress];
    }];
    
    return urls;
}

- (void)updateProgress {
    if (self.isCancelled) return;
    
    int start = (int)[[NSDate date] timeIntervalSince1970];
    int end = appDelegate.latestCachedImageDate;
    int seconds = start - (end ? end : start);
    __block int hours = (int)round(seconds / 60.f / 60.f);
    
    __block float progress = 0.f;
    if (appDelegate.totalUncachedImagesCount) {
        progress = 1.f - ((float)appDelegate.remainingUncachedImagesCount /
                          (float)appDelegate.totalUncachedImagesCount);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [appDelegate.feedsViewController showCachingNotifier:progress hoursBack:hours];
    });
}

- (void)storeCachedImage:(NSString *)imageUrl withImage:(UIImage *)image storyHash:(NSString *)storyHash storyTimestamp:(NSInteger)storyTimestamp {
    if (self.isCancelled) {
        NSLog(@"Image cancelled.");
        return;
    }
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW,
                                             (unsigned long)NULL), ^{
        
        NSData *responseData = UIImageJPEGRepresentation(image, 0.6);
        NSString *md5Url = [Utilities md5:imageUrl];
//            NSLog(@"Storing image: %@ (%d bytes - %d in queue)", storyHash, [responseData length], [imageDownloadOperationQueue requestsCount]);
        
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        NSString *cacheDirectory = [[paths objectAtIndex:0] stringByAppendingPathComponent:@"story_images"];
        NSString *fullPath = [cacheDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", md5Url, [imageUrl pathExtension]]];
        
        [fileManager createFileAtPath:fullPath contents:responseData attributes:nil];
        
        [appDelegate.database inDatabase:^(FMDatabase *db) {
            [db executeUpdate:@"UPDATE cached_images SET "
             "image_cached = 1 WHERE story_hash = ?",
             storyHash];
        }];
        
        if ([[[NSUserDefaults standardUserDefaults] objectForKey:@"default_order"] isEqualToString:@"oldest"]) {
            if (storyTimestamp > appDelegate.latestCachedImageDate) {
                appDelegate.latestCachedImageDate = storyTimestamp;
            }
        } else {
            if (!appDelegate.latestCachedImageDate || storyTimestamp < appDelegate.latestCachedImageDate) {
                appDelegate.latestCachedImageDate = storyTimestamp;
            }
        }
        
        appDelegate.remainingUncachedImagesCount--;
        if (appDelegate.remainingUncachedImagesCount % 10 == 0) {
            [self updateProgress];
        }
    });
}

- (void)storeFailedImage:(NSString *)storyHash {
    [appDelegate.database inDatabase:^(FMDatabase *db) {
        [db executeUpdate:@"UPDATE cached_images SET "
         "image_cached = 1, failed = 1 WHERE story_hash = ?",
         storyHash];
    }];
}

- (void)cachedImageQueueFinished {
    NSLog(@"Queue finished: %d total (%d remaining)", appDelegate.totalUncachedImagesCount, appDelegate.remainingUncachedImagesCount);
    [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
    [self fetchImages];
    //    dispatch_async(dispatch_get_main_queue(), ^{
    //        [self.feedsViewController hideNotifier];
    //    });
}

@end
