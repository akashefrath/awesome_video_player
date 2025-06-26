// AVPlayerPool.h
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

@interface AVPlayerPool : NSObject

+ (instancetype)sharedPool;

- (void)preparePoolWithSize:(NSUInteger)size;
- (AVPlayer *)dequeuePlayer;
- (void)enqueuePlayer:(AVPlayer *)player;
- (void)drainPool;

@property (nonatomic) NSUInteger poolSizeLimit;

@end

// AVPlayerPool.m
#import "AVPlayerPool.h"

@interface AVPlayerPool ()
@property (nonatomic, strong) NSMutableArray<AVPlayer *> *playerPool;
@property (nonatomic, strong) NSMutableArray<AVPlayer *> *preparedPlayers;
@property (nonatomic, strong) dispatch_queue_t synchronizationQueue;
@property (nonatomic, strong) dispatch_queue_t preparationQueue;
@end

@implementation AVPlayerPool

+ (instancetype)sharedPool {
    static AVPlayerPool *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _playerPool = [NSMutableArray array];
        _preparedPlayers = [NSMutableArray array];
        _synchronizationQueue = dispatch_queue_create("com.yourapp.avplayerpool.sync", DISPATCH_QUEUE_SERIAL);
        _preparationQueue = dispatch_queue_create("com.yourapp.avplayerpool.prep", DISPATCH_QUEUE_SERIAL);
        _poolSizeLimit = 5; // Default limit
    }
    return self;
}

- (void)preparePoolWithSize:(NSUInteger)size {
    dispatch_async(self.preparationQueue, ^{
        for (NSUInteger i = 0; i < size; i++) {
            AVPlayer *player = [[AVPlayer alloc] init];
            player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
            
            if (@available(iOS 10.0, *)) {
                player.automaticallyWaitsToMinimizeStalling = NO;
            }
            
            dispatch_sync(self.synchronizationQueue, ^{
                [self.preparedPlayers addObject:player];
            });
        }
    });
}

- (AVPlayer *)dequeuePlayer {
    __block AVPlayer *player = nil;
    
    dispatch_sync(self.synchronizationQueue, ^{
        // First try to get from prepared players
        if (self.preparedPlayers.count > 0) {
            player = [self.preparedPlayers lastObject];
            [self.preparedPlayers removeLastObject];
        } 
        // Then try regular pool
        else if (self.playerPool.count > 0) {
            player = [self.playerPool lastObject];
            [self.playerPool removeLastObject];
        } 
        // Create new if none available
        else {
            player = [[AVPlayer alloc] init];
            player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
            
            if (@available(iOS 10.0, *)) {
                player.automaticallyWaitsToMinimizeStalling = NO;
            }
        }
    });
    
    return player;
}

- (void)enqueuePlayer:(AVPlayer *)player {
    dispatch_async(self.synchronizationQueue, ^{
        // Reset player state before pooling
        [player pause];
        [player seekToTime:kCMTimeZero];
        [player cancelPendingPrerolls];
        [player replaceCurrentItemWithPlayerItem:nil];
        
        // Only keep player if under limit
        if (self.playerPool.count < self.poolSizeLimit) {
            [self.playerPool addObject:player];
        }
    });
}

- (void)drainPool {
    dispatch_async(self.synchronizationQueue, ^{
        [self.playerPool removeAllObjects];
        [self.preparedPlayers removeAllObjects];
    });
}

@end