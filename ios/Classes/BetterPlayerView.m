// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "BetterPlayerView.h"

// BetterPlayerView.m

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super init];
    NSAssert(self, @"super init cannot be nil");
    _isInitialized = false;
    _isPlaying = false;
    _disposed = false;
    
    // Get player from pool instead of creating new
    _player = [[AVPlayerPool sharedPool] dequeuePlayer];
    _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    
    if (@available(iOS 10.0, *)) {
        _player.automaticallyWaitsToMinimizeStalling = false;
    }
    
    self._observersAdded = false;
    return self;
}

- (void)disposeSansEventChannel {
    @try{
        [self clear];
        
        // Return player to pool when disposing
        if (_player) {
            [[AVPlayerPool sharedPool] enqueuePlayer:_player];
            _player = nil;
        }
    }
    @catch(NSException *exception) {
        NSLog(exception.debugDescription);
    }
}