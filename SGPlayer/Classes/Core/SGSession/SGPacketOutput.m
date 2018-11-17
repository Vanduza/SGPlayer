//
//  SGURLSource.m
//  SGPlayer
//
//  Created by Single on 2018/1/16.
//  Copyright © 2018年 single. All rights reserved.
//

#import "SGPacketOutput.h"
#import "SGError.h"
#import "SGMacro.h"
#import "SGLock.h"

@interface SGPacketOutput () <SGDemuxableDelegate>

{
    SGPacketOutputState _state;
    __strong NSError * _error;
}

@property (nonatomic, strong) id <SGDemuxable> demuxable;

@property (nonatomic, strong) NSLock * lock;
@property (nonatomic, strong) NSCondition * wakeup;
@property (nonatomic, strong) NSOperationQueue * operationQueue;

@property (nonatomic) CMTime seekTime;
@property (nonatomic) CMTime seekingTime;
@property (nonatomic, copy) SGSeekResultBlock seekResult;

@end

@implementation SGPacketOutput

- (instancetype)initWithDemuxable:(id <SGDemuxable>)demuxable
{
    if (self = [super init]) {
        self.demuxable = demuxable;
        self.demuxable.delegate = self;
        self.lock = [[NSLock alloc] init];
        self.wakeup = [[NSCondition alloc] init];
    }
    return self;
}

- (void)dealloc
{
    SGLockCondEXE10(self.lock, ^BOOL {
        return self->_state != SGPacketOutputStateClosed;
    }, ^SGBlock {
        [self setState:SGPacketOutputStateClosed];
        [self.operationQueue cancelAllOperations];
        [self.operationQueue waitUntilAllOperationsAreFinished];
        return nil;
    });
}

#pragma mark - Mapping

SGGet0Map(CMTime, duration, self.demuxable)
SGGet0Map(NSDictionary *, metadata, self.demuxable)
SGGet0Map(NSArray <SGTrack *> *, tracks, self.demuxable)

#pragma mark - Setter & Getter

- (SGBlock)setState:(SGPacketOutputState)state
{
    if (_state == state) {
        return ^{};
    }
    _state = state;
    [self.wakeup lock];
    [self.wakeup broadcast];
    [self.wakeup unlock];
    return ^{
        [self.delegate packetOutput:self didChangeState:state];
    };
}

- (SGPacketOutputState)state
{
    __block SGPacketOutputState ret = SGPacketOutputStateNone;
    SGLockEXE00(self.lock, ^{
        ret = self->_state;
    });
    return ret;
}

- (NSError *)error
{
    __block NSError * ret = nil;
    SGLockEXE00(self.lock, ^{
        ret = [self->_error copy];
    });
    return ret;
}

#pragma mark - Interface

- (BOOL)open
{
    return SGLockCondEXE11(self.lock, ^BOOL {
        return self->_state == SGPacketOutputStateNone;
    }, ^SGBlock {
        return [self setState:SGPacketOutputStateOpening];
    }, ^BOOL(SGBlock block) {
        block();
        NSOperation * operation = [[NSInvocationOperation alloc] initWithTarget:self selector:@selector(runningThread) object:nil];
        self.operationQueue = [[NSOperationQueue alloc] init];
        self.operationQueue.qualityOfService = NSQualityOfServiceUserInteractive;
        [self.operationQueue addOperation:operation];
        return YES;
    });
}

- (BOOL)close
{
    return SGLockCondEXE11(self.lock, ^BOOL {
        return self->_state != SGPacketOutputStateClosed;
    }, ^SGBlock {
        return [self setState:SGPacketOutputStateClosed];
    }, ^BOOL(SGBlock block) {
        block();
        [self.operationQueue cancelAllOperations];
        [self.operationQueue waitUntilAllOperationsAreFinished];
        return YES;
    });
}

- (BOOL)pause
{
    return SGLockCondEXE10(self.lock, ^BOOL {
        return self->_state == SGPacketOutputStateReading || self->_state == SGPacketOutputStateSeeking;
    }, ^SGBlock {
        return [self setState:SGPacketOutputStatePaused];
    });
}

- (BOOL)resume
{
    return SGLockCondEXE10(self.lock, ^BOOL {
        return self->_state == SGPacketOutputStatePaused || self->_state == SGPacketOutputStateOpened;
    }, ^SGBlock {
        return [self setState:SGPacketOutputStateReading];
    });
}

#pragma mark - Seeking

- (BOOL)seekable
{
    return [self.demuxable seekable] == nil;
}

- (BOOL)seekToTime:(CMTime)time result:(SGSeekResultBlock)result
{
    if (![self seekable]) {
        return NO;
    }
    return SGLockCondEXE10(self.lock, ^BOOL {
        return self->_state == SGPacketOutputStateReading || self->_state == SGPacketOutputStatePaused || self->_state == SGPacketOutputStateSeeking || self->_state == SGPacketOutputStateFinished;
    }, ^SGBlock {
        SGBlock b1 = ^{}, b2 = ^{};
        if (self.seekResult) {
            CMTime lastSeekTime = self.seekTime;
            SGSeekResultBlock lastSeekResult = self.seekResult;
            b1 = ^{
                lastSeekResult(lastSeekTime,
                               SGECreateError(SGErrorCodePacketOutputCancelSeek,
                                              SGOperationCodePacketOutputSeek));
            };
        }
        self.seekTime = time;
        self.seekResult = result;
        b2 = [self setState:SGPacketOutputStateSeeking];
        return ^{
            b1(); b2();
        };
    });
}

#pragma mark - Thread

- (void)runningThread
{
    while (YES) {
        @autoreleasepool {
            [self.lock lock];
            if (self->_state == SGPacketOutputStateNone ||
                self->_state == SGPacketOutputStateClosed ||
                self->_state == SGPacketOutputStateFailed) {
                [self.lock unlock];
                break;
            } else if (self->_state == SGPacketOutputStateOpening) {
                [self.lock unlock];
                NSError * error = [self.demuxable open];
                [self.lock lock];
                self->_error = error;
                SGBlock b1 = [self setState:error ? SGPacketOutputStateFailed : SGPacketOutputStateOpened];
                [self.lock unlock];
                b1();
                continue;
            } else if (self->_state == SGPacketOutputStateOpened ||
                       self->_state == SGPacketOutputStatePaused ||
                       self->_state == SGPacketOutputStateFinished) {
                [self.wakeup lock];
                [self.lock unlock];
                [self.wakeup wait];
                [self.wakeup unlock];
                continue;
            } else if (self->_state == SGPacketOutputStateSeeking) {
                self.seekingTime = self.seekTime;
                CMTime seekingTime = self.seekingTime;
                [self.lock unlock];
                NSError * error = [self.demuxable seekToTime:seekingTime];
                [self.lock lock];
                if (self->_state == SGPacketOutputStateSeeking &&
                    CMTimeCompare(self.seekTime, seekingTime) != 0) {
                    [self.lock unlock];
                    continue;
                }
                SGBlock b1 = ^{}, b2 = ^{};
                if (self.seekResult) {
                    CMTime seekTime = self.seekTime;
                    SGSeekResultBlock seekResult = self.seekResult;
                    b1 = ^{
                        seekResult(seekTime, error);
                    };
                }
                b2 = [self setState:SGPacketOutputStateReading];
                self.seekTime = kCMTimeZero;
                self.seekingTime = kCMTimeZero;
                self.seekResult = nil;
                [self.lock unlock];
                b1(); b2();
                continue;
            } else if (self->_state == SGPacketOutputStateReading) {
                [self.lock unlock];
                SGPacket * packet = nil;
                NSError * error = [self.demuxable nextPacket:&packet];
                if (error) {
                    [self.lock lock];
                    SGBlock b1 = ^{};
                    if (self->_state == SGPacketOutputStateReading) {
                        b1 = [self setState:SGPacketOutputStateFinished];
                    }
                    [self.lock unlock];
                    b1();
                } else {
                    [self.delegate packetOutput:self didOutputPacket:packet];
                    [packet unlock];
                }
                continue;
            }
        }
    }
    [self.demuxable close];
}

#pragma mark - SGPacketReaderDelegate

- (BOOL)demuxableShouldAbortBlockingFunctions:(id <SGDemuxable>)demuxable
{
    return SGLockCondEXE00(self.lock, ^BOOL {
        switch (self->_state) {
            case SGPacketOutputStateFinished:
            case SGPacketOutputStateClosed:
            case SGPacketOutputStateFailed:
                return YES;
            case SGPacketOutputStateSeeking:
                return CMTimeCompare(self.seekTime, self.seekingTime) != 0;
            default:
                return NO;
        }
    }, nil);
}

@end
