#import <React/RCTConvert.h>
#import "RCTVideo.h"
#import <React/RCTBridgeModule.h>
#import <React/RCTEventDispatcher.h>
#import <React/UIView+React.h>
@import GoogleInteractiveMediaAds;
#include <MediaAccessibility/MediaAccessibility.h>
#include <AVFoundation/AVFoundation.h>

@interface RCTVideo () <IMAAdsLoaderDelegate, IMAAdsManagerDelegate>

@end

static NSString *const statusKeyPath = @"status";
static NSString *const playbackLikelyToKeepUpKeyPath = @"playbackLikelyToKeepUp";
static NSString *const playbackBufferEmptyKeyPath = @"playbackBufferEmpty";
static NSString *const readyForDisplayKeyPath = @"readyForDisplay";
static NSString *const playbackRate = @"rate";
static NSString *const timedMetadata = @"timedMetadata";

static int const RCTVideoUnset = -1;

#ifdef DEBUG
    #define DebugLog(...) NSLog(__VA_ARGS__)
#else
    #define DebugLog(...) (void)0
#endif

@implementation RCTVideo
{
  AVPlayer *_player;
  AVPlayerItem *_playerItem;
  BOOL _playerItemObserversSet;
  BOOL _playerBufferEmpty;
  AVPlayerLayer *_playerLayer;
  BOOL _playerLayerObserverSet;
  AVPlayerViewController *_playerViewController;
  NSURL *_videoURL;
  
  /* Required to publish events */
  RCTEventDispatcher *_eventDispatcher;
  BOOL _playbackRateObserverRegistered;
  BOOL _videoLoadStarted;

  bool _pendingSeek;
  float _pendingSeekTime;
  float _lastSeekTime;
  
  /* For sending videoProgress events */
  Float64 _progressUpdateInterval;
  BOOL _controls;
  id _timeObserver;
  
  /* Keep track of any modifiers, need to be applied after each play */
  float _volume;
  float _rate;
  BOOL _muted;
  BOOL _paused;
  BOOL _repeat;
  BOOL _allowsExternalPlayback;
  NSArray * _textTracks;
  NSDictionary * _selectedTextTrack;
  NSDictionary * _selectedAudioTrack;
  BOOL _playbackStalled;
  BOOL _playInBackground;
  BOOL _playWhenInactive;
  NSString * _ignoreSilentSwitch;
  NSString * _resizeMode;
  BOOL _fullscreenPlayerPresented;
  UIViewController * _presentingViewController;

  /* Ads Loader */
  IMAAdsLoader * _adsLoader;
  IMAAVPlayerContentPlayhead * _contentPlayhead;
  IMAAdsManager * _adsManager;

#if __has_include(<react-native-video/RCTVideoCache.h>)
  RCTVideoCache * _videoCache;
#endif
}

- (instancetype)initWithEventDispatcher:(RCTEventDispatcher *)eventDispatcher
{
  if ((self = [super init])) {
    _eventDispatcher = eventDispatcher;
    
    _playbackRateObserverRegistered = NO;
    _playbackStalled = NO;
    _rate = 1.0;
    _volume = 1.0;
    _resizeMode = @"AVLayerVideoGravityResizeAspectFill";
    _pendingSeek = false;
    _pendingSeekTime = 0.0f;
    _lastSeekTime = 0.0f;
    _progressUpdateInterval = 250;
    _controls = NO;
    _playerBufferEmpty = YES;
    _playInBackground = false;
    _allowsExternalPlayback = YES;
    _playWhenInactive = false;
    _ignoreSilentSwitch = @"inherit"; // inherit, ignore, obey

#if __has_include(<react-native-video/RCTVideoCache.h>)
    _videoCache = [RCTVideoCache sharedInstance];
#endif

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillResignActive:)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidEnterBackground:)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillEnterForeground:)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(audioRouteChanged:)
                                                 name:AVAudioSessionRouteChangeNotification
                                               object:nil];
  }
  
  return self;
}

- (void)requestAds:(NSString *) adTagUrl {
    _adsLoader = [[IMAAdsLoader alloc] initWithSettings:nil];
    _adsLoader.delegate = self;
    // Create an ad display container for ad rendering.
    IMAAdDisplayContainer *adDisplayContainer =
    [[IMAAdDisplayContainer alloc] initWithAdContainer:self companionSlots:nil];
    // Create an ad request with our ad tag, display container, and optional user context.
    IMAAdsRequest *request = [[IMAAdsRequest alloc] initWithAdTagUrl:adTagUrl
                                                  adDisplayContainer:adDisplayContainer
                                                     contentPlayhead:_contentPlayhead
                                                         userContext:nil];
    [_adsLoader requestAdsWithRequest:request];
}

- (void)adsLoader:(IMAAdsLoader *)loader adsLoadedWithData:(IMAAdsLoadedData *)adsLoadedData {
    // Grab the instance of the IMAAdsManager and set ourselves as the delegate.
    _adsManager = adsLoadedData.adsManager;
    
    _adsManager.delegate = self;
    
    // Create ads rendering settings and tell the SDK to use the in-app browser.
    IMAAdsRenderingSettings *adsRenderingSettings = [[IMAAdsRenderingSettings alloc] init];
    // adsRenderingSettings.webOpenerPresentingController = self;
    
    // Initialize the ads manager.
    [_adsManager initializeWithAdsRenderingSettings:adsRenderingSettings];
}

- (void)adsLoader:(IMAAdsLoader *)loader failedWithErrorData:(IMAAdLoadingErrorData *)adErrorData {
    // Something went wrong loading ads. Log the error and play the content.
    NSLog(@"Error loading ads: %@", adErrorData.adError.message);
    if (self.onAdError) {
        self.onAdError(@{@"target": self.reactTag});
    }
    [_player play];
}

- (AVPlayerViewController*)createPlayerViewController:(AVPlayer*)player withPlayerItem:(AVPlayerItem*)playerItem {
    RCTVideoPlayerViewController* playerLayer= [[RCTVideoPlayerViewController alloc] init];
    playerLayer.showsPlaybackControls = YES;
    playerLayer.rctDelegate = self;
    playerLayer.view.frame = self.bounds;
    playerLayer.player = player;
    playerLayer.view.frame = self.bounds;
    return playerLayer;
}

- (void)adsManager:(IMAAdsManager *)adsManager didReceiveAdEvent:(IMAAdEvent *)event {
    if (event.type == kIMAAdEvent_LOADED && self.onAdsLoaded) {
        self.onAdsLoaded(@{@"target": self.reactTag});
    } else if (event.type == kIMAAdEvent_AD_BREAK_STARTED && self.onAdStarted) {
        self.onAdStarted(@{@"target": self.reactTag});
    } else if (event.type == kIMAAdEvent_ALL_ADS_COMPLETED && self.onAdsComplete) {
        if (_adsManager) {
            [_adsManager destroy];
            _adsManager = nil;
        }
        self.onAdsComplete(@{@"target": self.reactTag});
    }
}

- (void)startAds
{
    [_adsManager start];
}

- (void)adsManager:(IMAAdsManager *)adsManager didReceiveAdError:(IMAAdError *)error {
    // Something went wrong with the ads manager after ads were loaded. Log the error and play the
    // content.
    NSLog(@"AdsManager error: %@", error.message);
    [_player play];
}

- (void)adsManagerDidRequestContentPause:(IMAAdsManager *)adsManager {
    // The SDK is going to play ads, so pause the content.
    [_player pause];
}

- (void)adsManagerDidRequestContentResume:(IMAAdsManager *)adsManager {
    // The SDK is done playing ads (at least for now), so resume the content.
    [_player play];
}

/* ---------------------------------------------------------
 **  Get the duration for a AVPlayerItem.
 ** ------------------------------------------------------- */

- (CMTime)playerItemDuration
{
  AVPlayerItem *playerItem = [_player currentItem];
  if (playerItem.status == AVPlayerItemStatusReadyToPlay)
  {
    return([playerItem duration]);
  }
  
  return(kCMTimeInvalid);
}

- (CMTimeRange)playerItemSeekableTimeRange
{
  AVPlayerItem *playerItem = [_player currentItem];
  if (playerItem.status == AVPlayerItemStatusReadyToPlay)
  {
    return [playerItem seekableTimeRanges].firstObject.CMTimeRangeValue;
  }
  
  return (kCMTimeRangeZero);
}

-(void)addPlayerTimeObserver
{
  const Float64 progressUpdateIntervalMS = _progressUpdateInterval / 1000;
  // @see endScrubbing in AVPlayerDemoPlaybackViewController.m
  // of https://developer.apple.com/library/ios/samplecode/AVPlayerDemo/Introduction/Intro.html
  __weak RCTVideo *weakSelf = self;
  _timeObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(progressUpdateIntervalMS, NSEC_PER_SEC)
                                                        queue:NULL
                                                   usingBlock:^(CMTime time) { [weakSelf sendProgressUpdate]; }
                   ];
}

/* Cancels the previously registered time observer. */
-(void)removePlayerTimeObserver
{
  if (_timeObserver)
  {
    [_player removeTimeObserver:_timeObserver];
    _timeObserver = nil;
  }
}

#pragma mark - Progress

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [self removePlayerLayer];
  [self removePlayerItemObservers];
  [_player removeObserver:self forKeyPath:playbackRate context:nil];
}

#pragma mark - App lifecycle handlers

- (void)applicationWillResignActive:(NSNotification *)notification
{
  if (_playInBackground || _playWhenInactive || _paused) return;
  
  [_player pause];
  [_player setRate:0.0];
}

- (void)applicationDidEnterBackground:(NSNotification *)notification
{
  if (_playInBackground) {
    // Needed to play sound in background. See https://developer.apple.com/library/ios/qa/qa1668/_index.html
    [_playerLayer setPlayer:nil];
  }
}

- (void)applicationWillEnterForeground:(NSNotification *)notification
{
  [self applyModifiers];
  if (_playInBackground) {
    [_playerLayer setPlayer:_player];
  }
  if (_adsManager) {
    [_adsManager resume];
  }
}

#pragma mark - Audio events

- (void)audioRouteChanged:(NSNotification *)notification
{
    NSNumber *reason = [[notification userInfo] objectForKey:AVAudioSessionRouteChangeReasonKey];
    NSNumber *previousRoute = [[notification userInfo] objectForKey:AVAudioSessionRouteChangePreviousRouteKey];
    if (reason.unsignedIntValue == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
        self.onVideoAudioBecomingNoisy(@{@"target": self.reactTag});
    }
}

#pragma mark - Progress

- (void)sendProgressUpdate
{
  AVPlayerItem *video = [_player currentItem];
  if (video == nil || video.status != AVPlayerItemStatusReadyToPlay) {
    return;
  }
  
  CMTime playerDuration = [self playerItemDuration];
  if (CMTIME_IS_INVALID(playerDuration)) {
    return;
  }
  
  CMTime currentTime = _player.currentTime;
  const Float64 duration = CMTimeGetSeconds(playerDuration);
  const Float64 currentTimeSecs = CMTimeGetSeconds(currentTime);
  
  [[NSNotificationCenter defaultCenter] postNotificationName:@"RCTVideo_progress" object:nil userInfo:@{@"progress": [NSNumber numberWithDouble: currentTimeSecs / duration]}];
  
  if( currentTimeSecs >= 0 && self.onVideoProgress) {
    self.onVideoProgress(@{
                           @"currentTime": [NSNumber numberWithFloat:CMTimeGetSeconds(currentTime)],
                           @"playableDuration": [self calculatePlayableDuration],
                           @"atValue": [NSNumber numberWithLongLong:currentTime.value],
                           @"atTimescale": [NSNumber numberWithInt:currentTime.timescale],
                           @"target": self.reactTag,
                           @"seekableDuration": [self calculateSeekableDuration],
                           });
  }
}

/*!
 * Calculates and returns the playable duration of the current player item using its loaded time ranges.
 *
 * \returns The playable duration of the current player item in seconds.
 */
- (NSNumber *)calculatePlayableDuration
{
  AVPlayerItem *video = _player.currentItem;
  if (video.status == AVPlayerItemStatusReadyToPlay) {
    __block CMTimeRange effectiveTimeRange;
    [video.loadedTimeRanges enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
      CMTimeRange timeRange = [obj CMTimeRangeValue];
      if (CMTimeRangeContainsTime(timeRange, video.currentTime)) {
        effectiveTimeRange = timeRange;
        *stop = YES;
      }
    }];
    Float64 playableDuration = CMTimeGetSeconds(CMTimeRangeGetEnd(effectiveTimeRange));
    if (playableDuration > 0) {
      return [NSNumber numberWithFloat:playableDuration];
    }
  }
  return [NSNumber numberWithInteger:0];
}

- (NSNumber *)calculateSeekableDuration
{
  CMTimeRange timeRange = [self playerItemSeekableTimeRange];
  if (CMTIME_IS_NUMERIC(timeRange.duration))
  {
    return [NSNumber numberWithFloat:CMTimeGetSeconds(timeRange.duration)];
  }
  return [NSNumber numberWithInteger:0];
}

- (void)addPlayerItemObservers
{
  [_playerItem addObserver:self forKeyPath:statusKeyPath options:0 context:nil];
  [_playerItem addObserver:self forKeyPath:playbackBufferEmptyKeyPath options:0 context:nil];
  [_playerItem addObserver:self forKeyPath:playbackLikelyToKeepUpKeyPath options:0 context:nil];
  [_playerItem addObserver:self forKeyPath:timedMetadata options:NSKeyValueObservingOptionNew context:nil];
  _playerItemObserversSet = YES;
}

/* Fixes https://github.com/brentvatne/react-native-video/issues/43
 * Crashes caused when trying to remove the observer when there is no
 * observer set */
- (void)removePlayerItemObservers
{
  if (_playerItemObserversSet) {
    [_playerItem removeObserver:self forKeyPath:statusKeyPath];
    [_playerItem removeObserver:self forKeyPath:playbackBufferEmptyKeyPath];
    [_playerItem removeObserver:self forKeyPath:playbackLikelyToKeepUpKeyPath];
    [_playerItem removeObserver:self forKeyPath:timedMetadata];
    _playerItemObserversSet = NO;
  }
}

#pragma mark - Player and source

- (void)setSrc:(NSDictionary *)source
{
  [self removePlayerLayer];
  [self removePlayerTimeObserver];
  [self removePlayerItemObservers];

  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) 0), dispatch_get_main_queue(), ^{

    // perform on next run loop, otherwise other passed react-props may not be set
    [self playerItemForSource:source withCallback:^(AVPlayerItem * playerItem) {
      _playerItem = playerItem;
      [self addPlayerItemObservers];
      
      [_player pause];
      [_playerViewController.view removeFromSuperview];
      _playerViewController = nil;
        
      if (_playbackRateObserverRegistered) {
        [_player removeObserver:self forKeyPath:playbackRate context:nil];
        _playbackRateObserverRegistered = NO;
      }
        
      _player = [AVPlayer playerWithPlayerItem:_playerItem];
      _contentPlayhead = [[IMAAVPlayerContentPlayhead alloc] initWithAVPlayer:_player];
      _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
        
      [_player addObserver:self forKeyPath:playbackRate options:0 context:nil];
      _playbackRateObserverRegistered = YES;
        
      [self addPlayerTimeObserver];
        
      //Perform on next run loop, otherwise onVideoLoadStart is nil
      if (self.onVideoLoadStart) {
        id uri = [source objectForKey:@"uri"];
        id type = [source objectForKey:@"type"];
        self.onVideoLoadStart(@{@"src": @{
                                        @"uri": uri ? uri : [NSNull null],
                                        @"type": type ? type : [NSNull null],
                                        @"isNetwork": [NSNumber numberWithBool:(bool)[source objectForKey:@"isNetwork"]]},
                                    @"target": self.reactTag
                                });
      }
    }];
  });
  _videoLoadStarted = YES;
}

- (NSURL*) urlFilePath:(NSString*) filepath {
  if ([filepath containsString:@"file://"]) {
    return [NSURL URLWithString:filepath];
  }
  
  // code to support local caching
  NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
  NSString* relativeFilePath = [filepath lastPathComponent];
  // the file may be multiple levels below the documents directory
  NSArray* fileComponents = [filepath componentsSeparatedByString:@"Documents/"];
  if (fileComponents.count > 1) {
    relativeFilePath = [fileComponents objectAtIndex:1];
  }
  
  NSString *path = [paths.firstObject stringByAppendingPathComponent:relativeFilePath];
  if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
    return [NSURL fileURLWithPath:path];
  }
  return nil;
}

- (void)playerItemPrepareText:(AVAsset *)asset assetOptions:(NSDictionary * __nullable)assetOptions withCallback:(void(^)(AVPlayerItem *))handler
{
  if (!_textTracks) {
    handler([AVPlayerItem playerItemWithAsset:asset]);
    return;
  }

  // sideload text tracks
  AVMutableComposition *mixComposition = [[AVMutableComposition alloc] init];
  
  AVAssetTrack *videoAsset = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
  AVMutableCompositionTrack *videoCompTrack = [mixComposition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
  [videoCompTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, videoAsset.timeRange.duration)
                          ofTrack:videoAsset
                           atTime:kCMTimeZero
                            error:nil];

  AVAssetTrack *audioAsset = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
  AVMutableCompositionTrack *audioCompTrack = [mixComposition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
  [audioCompTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, videoAsset.timeRange.duration)
                          ofTrack:audioAsset
                           atTime:kCMTimeZero
                            error:nil];

  NSMutableArray* validTextTracks = [NSMutableArray array];
  for (int i = 0; i < _textTracks.count; ++i) {
    AVURLAsset *textURLAsset;
    NSString *textUri = [_textTracks objectAtIndex:i][@"uri"];
    if ([[textUri lowercaseString] hasPrefix:@"http"]) {
      textURLAsset = [AVURLAsset URLAssetWithURL:[NSURL URLWithString:textUri] options:assetOptions];
    } else {
      textURLAsset = [AVURLAsset URLAssetWithURL:[self urlFilePath:textUri] options:nil];
    }
    AVAssetTrack *textTrackAsset = [textURLAsset tracksWithMediaType:AVMediaTypeText].firstObject;
    if (!textTrackAsset) continue; // fix when there's no textTrackAsset
    [validTextTracks addObject:[_textTracks objectAtIndex:i]];
    AVMutableCompositionTrack *textCompTrack = [mixComposition
                                                addMutableTrackWithMediaType:AVMediaTypeText
                                                preferredTrackID:kCMPersistentTrackID_Invalid];
    [textCompTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, videoAsset.timeRange.duration)
                               ofTrack:textTrackAsset
                                atTime:kCMTimeZero
                                 error:nil];
  }
  if (validTextTracks.count != _textTracks.count) {
    [self setTextTracks:validTextTracks];
  }

  handler([AVPlayerItem playerItemWithAsset:mixComposition]);
}

- (void)playerItemForSource:(NSDictionary *)source withCallback:(void(^)(AVPlayerItem *))handler
{
  bool isNetwork = [RCTConvert BOOL:[source objectForKey:@"isNetwork"]];
  bool isAsset = [RCTConvert BOOL:[source objectForKey:@"isAsset"]];
  NSString *uri = [source objectForKey:@"uri"];
  NSString *type = [source objectForKey:@"type"];

  NSURL *url = isNetwork || isAsset
    ? [NSURL URLWithString:uri]
    : [[NSURL alloc] initFileURLWithPath:[[NSBundle mainBundle] pathForResource:uri ofType:type]];
  NSMutableDictionary *assetOptions = [[NSMutableDictionary alloc] init];
  
  if (isNetwork) {
    /* Per #1091, this is not a public API.
     * We need to either get approval from Apple to use this  or use a different approach.
     NSDictionary *headers = [source objectForKey:@"requestHeaders"];
     if ([headers count] > 0) {
       [assetOptions setObject:headers forKey:@"AVURLAssetHTTPHeaderFieldsKey"];
     }
     */
    NSArray *cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies];
    [assetOptions setObject:cookies forKey:AVURLAssetHTTPCookiesKey];

#if __has_include(<react-native-video/RCTVideoCache.h>)
    if (!_textTracks) {
      /* The DVURLAsset created by cache doesn't have a tracksWithMediaType property, so trying
       *  to bring in the text track code will crash. I suspect this is because the asset hasn't fully loaded.
       * Until this is fixed, we need to bypass caching when text tracks are specified.
       */
      DebugLog(@"Caching is not supported for uri '%@' because text tracks are not compatible with the cache. Checkout https://github.com/react-native-community/react-native-video/blob/master/docs/caching.md", uri);
      [self playerItemForSourceUsingCache:uri assetOptions:assetOptions withCallback:handler];
      return;
    }
#endif

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:assetOptions];
    [self playerItemPrepareText:asset assetOptions:assetOptions withCallback:handler];
    return;
  } else if (isAsset) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    [self playerItemPrepareText:asset assetOptions:assetOptions withCallback:handler];
    return;
  }

  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[[NSURL alloc] initFileURLWithPath:[[NSBundle mainBundle] pathForResource:uri ofType:type]] options:nil];
  [self playerItemPrepareText:asset assetOptions:assetOptions withCallback:handler];
}

#if __has_include(<react-native-video/RCTVideoCache.h>)

- (void)playerItemForSourceUsingCache:(NSString *)uri assetOptions:(NSDictionary *)options withCallback:(void(^)(AVPlayerItem *))handler {
    NSURL *url = [NSURL URLWithString:uri];
    [_videoCache getItemForUri:uri withCallback:^(RCTVideoCacheStatus videoCacheStatus, AVAsset * _Nullable cachedAsset) {
        switch (videoCacheStatus) {
            case RCTVideoCacheStatusMissingFileExtension: {
                DebugLog(@"Could not generate cache key for uri '%@'. It is currently not supported to cache urls that do not include a file extension. The video file will not be cached. Checkout https://github.com/react-native-community/react-native-video/blob/master/docs/caching.md", uri);
                AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:options];
                [self playerItemPrepareText:asset assetOptions:options withCallback:handler];
                return;
            }
            case RCTVideoCacheStatusUnsupportedFileExtension: {
                DebugLog(@"Could not generate cache key for uri '%@'. The file extension of that uri is currently not supported. The video file will not be cached. Checkout https://github.com/react-native-community/react-native-video/blob/master/docs/caching.md", uri);
                AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:options];
                [self playerItemPrepareText:asset assetOptions:options withCallback:handler];
                return;
            }
            default:
                if (cachedAsset) {
                    DebugLog(@"Playing back uri '%@' from cache", uri);
                    // See note in playerItemForSource about not being able to support text tracks & caching
                    handler([AVPlayerItem playerItemWithAsset:asset]);
                    return;
                }
        }

        DVURLAsset *asset = [[DVURLAsset alloc] initWithURL:url options:options networkTimeout:10000];
        asset.loaderDelegate = self;
        
        /* More granular code to have control over the DVURLAsset
        DVAssetLoaderDelegate *resourceLoaderDelegate = [[DVAssetLoaderDelegate alloc] initWithURL:url];
        resourceLoaderDelegate.delegate = self;
        NSURLComponents *components = [[NSURLComponents alloc] initWithURL:url resolvingAgainstBaseURL:NO];
        components.scheme = [DVAssetLoaderDelegate scheme];
        AVURLAsset *asset = [[AVURLAsset alloc] initWithURL:[components URL] options:options];
        [asset.resourceLoader setDelegate:resourceLoaderDelegate queue:dispatch_get_main_queue()];
        */

        handler([AVPlayerItem playerItemWithAsset:asset]);
    }];
}

#pragma mark - DVAssetLoaderDelegate

- (void)dvAssetLoaderDelegate:(DVAssetLoaderDelegate *)loaderDelegate
                  didLoadData:(NSData *)data
                       forURL:(NSURL *)url {
    [_videoCache storeItem:data forUri:[url absoluteString] withCallback:^(BOOL success) {
        DebugLog(@"Cache data stored successfully 🎉");
    }];
}

#endif

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
  if (object == _playerItem) {
    // When timeMetadata is read the event onTimedMetadata is triggered
    if ([keyPath isEqualToString:timedMetadata]) {
      NSArray<AVMetadataItem *> *items = [change objectForKey:@"new"];
      if (items && ![items isEqual:[NSNull null]] && items.count > 0) {
        NSMutableArray *array = [NSMutableArray new];
        for (AVMetadataItem *item in items) {
          NSString *value = (NSString *)item.value;
          NSString *identifier = item.identifier;
          
          if (![value isEqual: [NSNull null]]) {
            NSDictionary *dictionary = [[NSDictionary alloc] initWithObjects:@[value, identifier] forKeys:@[@"value", @"identifier"]];
            
            [array addObject:dictionary];
          }
        }
        
        self.onTimedMetadata(@{
                               @"target": self.reactTag,
                               @"metadata": array
                               });
      }
    }
    
    if ([keyPath isEqualToString:statusKeyPath]) {
      // Handle player item status change.
      if (_playerItem.status == AVPlayerItemStatusReadyToPlay) {
        float duration = CMTimeGetSeconds(_playerItem.asset.duration);
        
        if (isnan(duration)) {
          duration = 0.0;
        }
        
        NSObject *width = @"undefined";
        NSObject *height = @"undefined";
        NSString *orientation = @"undefined";
        
        if ([_playerItem.asset tracksWithMediaType:AVMediaTypeVideo].count > 0) {
          AVAssetTrack *videoTrack = [[_playerItem.asset tracksWithMediaType:AVMediaTypeVideo] objectAtIndex:0];
          width = [NSNumber numberWithFloat:videoTrack.naturalSize.width];
          height = [NSNumber numberWithFloat:videoTrack.naturalSize.height];
          CGAffineTransform preferredTransform = [videoTrack preferredTransform];
          
          if ((videoTrack.naturalSize.width == preferredTransform.tx
               && videoTrack.naturalSize.height == preferredTransform.ty)
              || (preferredTransform.tx == 0 && preferredTransform.ty == 0))
          {
            orientation = @"landscape";
          } else {
            orientation = @"portrait";
          }
        }
        
        if (self.onVideoLoad && _videoLoadStarted) {
          self.onVideoLoad(@{@"duration": [NSNumber numberWithFloat:duration],
                             @"currentTime": [NSNumber numberWithFloat:CMTimeGetSeconds(_playerItem.currentTime)],
                             @"canPlayReverse": [NSNumber numberWithBool:_playerItem.canPlayReverse],
                             @"canPlayFastForward": [NSNumber numberWithBool:_playerItem.canPlayFastForward],
                             @"canPlaySlowForward": [NSNumber numberWithBool:_playerItem.canPlaySlowForward],
                             @"canPlaySlowReverse": [NSNumber numberWithBool:_playerItem.canPlaySlowReverse],
                             @"canStepBackward": [NSNumber numberWithBool:_playerItem.canStepBackward],
                             @"canStepForward": [NSNumber numberWithBool:_playerItem.canStepForward],
                             @"naturalSize": @{
                                 @"width": width,
                                 @"height": height,
                                 @"orientation": orientation
                                 },
                             @"audioTracks": [self getAudioTrackInfo],
                             @"textTracks": [self getTextTrackInfo],
                             @"target": self.reactTag});
        }
        _videoLoadStarted = NO;
        
        [self attachListeners];
        [self applyModifiers];
      } else if (_playerItem.status == AVPlayerItemStatusFailed && self.onVideoError) {
        self.onVideoError(@{@"error": @{@"code": [NSNumber numberWithInteger: _playerItem.error.code],
                                        @"domain": _playerItem.error.domain},
                            @"target": self.reactTag});
      }
    } else if ([keyPath isEqualToString:playbackBufferEmptyKeyPath]) {
      _playerBufferEmpty = YES;
      self.onVideoBuffer(@{@"isBuffering": @(YES), @"target": self.reactTag});
    } else if ([keyPath isEqualToString:playbackLikelyToKeepUpKeyPath]) {
      // Continue playing (or not if paused) after being paused due to hitting an unbuffered zone.
      if ((!(_controls || _fullscreenPlayerPresented) || _playerBufferEmpty) && _playerItem.playbackLikelyToKeepUp) {
        [self setPaused:_paused];
      }
      _playerBufferEmpty = NO;
      self.onVideoBuffer(@{@"isBuffering": @(NO), @"target": self.reactTag});
    }
  } else if (object == _playerLayer) {
    if([keyPath isEqualToString:readyForDisplayKeyPath] && [change objectForKey:NSKeyValueChangeNewKey]) {
      if([change objectForKey:NSKeyValueChangeNewKey] && self.onReadyForDisplay) {
        self.onReadyForDisplay(@{@"target": self.reactTag});
      }
    }
  } else if (object == _player) {
    if([keyPath isEqualToString:playbackRate]) {
      if(self.onPlaybackRateChange) {
        self.onPlaybackRateChange(@{@"playbackRate": [NSNumber numberWithFloat:_player.rate],
                                    @"target": self.reactTag});
      }
      if(_playbackStalled && _player.rate > 0) {
        if(self.onPlaybackResume) {
          self.onPlaybackResume(@{@"playbackRate": [NSNumber numberWithFloat:_player.rate],
                                  @"target": self.reactTag});
        }
        _playbackStalled = NO;
      }
    }
  } else {
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
  }
}

- (void)attachListeners
{
  // listen for end of file
  [[NSNotificationCenter defaultCenter] removeObserver:self
                                                  name:AVPlayerItemDidPlayToEndTimeNotification
                                                object:[_player currentItem]];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(playerItemDidReachEnd:)
                                               name:AVPlayerItemDidPlayToEndTimeNotification
                                             object:[_player currentItem]];

  [[NSNotificationCenter defaultCenter] removeObserver:self
                                                  name:AVPlayerItemPlaybackStalledNotification
                                                object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(playbackStalled:)
                                               name:AVPlayerItemPlaybackStalledNotification
                                             object:nil];
}

- (void)playbackStalled:(NSNotification *)notification
{
  if(self.onPlaybackStalled) {
    self.onPlaybackStalled(@{@"target": self.reactTag});
  }
  _playbackStalled = YES;
}

- (void)playerItemDidReachEnd:(NSNotification *)notification
{
  if(self.onVideoEnd) {
    self.onVideoEnd(@{@"target": self.reactTag});
  }
  
  if (_repeat) {
    AVPlayerItem *item = [notification object];
    [item seekToTime:kCMTimeZero];
    [self applyModifiers];
  } else {
    [self removePlayerTimeObserver];
  }
}

#pragma mark - Prop setters

- (void)setResizeMode:(NSString*)mode
{
  if( _controls )
  {
    _playerViewController.videoGravity = mode;
  }
  else
  {
    _playerLayer.videoGravity = mode;
  }
  _resizeMode = mode;
}

- (void)setPlayInBackground:(BOOL)playInBackground
{
  _playInBackground = playInBackground;
}

- (void)setAllowsExternalPlayback:(BOOL)allowsExternalPlayback
{
    _allowsExternalPlayback = allowsExternalPlayback;
    _player.allowsExternalPlayback = _allowsExternalPlayback;
}

- (void)setPlayWhenInactive:(BOOL)playWhenInactive
{
  _playWhenInactive = playWhenInactive;
}

- (void)setIgnoreSilentSwitch:(NSString *)ignoreSilentSwitch
{
  _ignoreSilentSwitch = ignoreSilentSwitch;
  [self applyModifiers];
}

- (void)setPaused:(BOOL)paused
{
  if (paused) {
    [_player pause];
    [_player setRate:0.0];
  } else {
    if([_ignoreSilentSwitch isEqualToString:@"ignore"]) {
      [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
    } else if([_ignoreSilentSwitch isEqualToString:@"obey"]) {
      [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient error:nil];
    }
    [_player play];
    [_player setRate:_rate];
  }
  
  _paused = paused;
}

- (float)getCurrentTime
{
  return _playerItem != NULL ? CMTimeGetSeconds(_playerItem.currentTime) : 0;
}

- (void)setCurrentTime:(float)currentTime
{
  NSDictionary *info = @{
                         @"time": [NSNumber numberWithFloat:currentTime],
                         @"tolerance": [NSNumber numberWithInt:100]
                         };
  [self setSeek:info];
}

- (void)setSeek:(NSDictionary *)info
{
  NSNumber *seekTime = info[@"time"];
  NSNumber *seekTolerance = info[@"tolerance"];
  
  int timeScale = 1000;
  
  AVPlayerItem *item = _player.currentItem;
  if (item && item.status == AVPlayerItemStatusReadyToPlay) {
    // TODO check loadedTimeRanges
    
    CMTime cmSeekTime = CMTimeMakeWithSeconds([seekTime floatValue], timeScale);
    CMTime current = item.currentTime;
    // TODO figure out a good tolerance level
    CMTime tolerance = CMTimeMake([seekTolerance floatValue], timeScale);
    BOOL wasPaused = _paused;
    
    if (CMTimeCompare(current, cmSeekTime) != 0) {
      if (!wasPaused) [_player pause];
      [_player seekToTime:cmSeekTime toleranceBefore:tolerance toleranceAfter:tolerance completionHandler:^(BOOL finished) {
        if (!_timeObserver) {
          [self addPlayerTimeObserver];
        }
        if (!wasPaused) {
          [self setPaused:false];
        }
        if(self.onVideoSeek) {
          self.onVideoSeek(@{@"currentTime": [NSNumber numberWithFloat:CMTimeGetSeconds(item.currentTime)],
                             @"seekTime": seekTime,
                             @"target": self.reactTag});
        }
      }];
      
      _pendingSeek = false;
    }
    
  } else {
    // TODO: See if this makes sense and if so, actually implement it
    _pendingSeek = true;
    _pendingSeekTime = [seekTime floatValue];
  }
}

- (void)setRate:(float)rate
{
  _rate = rate;
  [self applyModifiers];
}

- (void)setMuted:(BOOL)muted
{
  _muted = muted;
  [self applyModifiers];
}

- (void)setVolume:(float)volume
{
  _volume = volume;
  [self applyModifiers];
}

- (void)applyModifiers
{
  if (_muted) {
    [_player setVolume:0];
    [_player setMuted:YES];
  } else {
    [_player setVolume:_volume];
    [_player setMuted:NO];
  }

  [self setSelectedAudioTrack:_selectedAudioTrack];
  [self setSelectedTextTrack:_selectedTextTrack];
  [self setResizeMode:_resizeMode];
  [self setRepeat:_repeat];
  [self setPaused:_paused];
  [self setControls:_controls];
  [self setAllowsExternalPlayback:_allowsExternalPlayback];
}

- (void)setRepeat:(BOOL)repeat {
  _repeat = repeat;
}

- (void)setMediaSelectionTrackForCharacteristic:(AVMediaCharacteristic)characteristic
                                   withCriteria:(NSDictionary *)criteria
{
    NSString *type = criteria[@"type"];
    AVMediaSelectionGroup *group = [_player.currentItem.asset
                                    mediaSelectionGroupForMediaCharacteristic:characteristic];
    AVMediaSelectionOption *mediaOption;
    
    if ([type isEqualToString:@"disabled"]) {
        // Do nothing. We want to ensure option is nil
    } else if ([type isEqualToString:@"language"] || [type isEqualToString:@"title"]) {
        NSString *value = criteria[@"value"];
        for (int i = 0; i < group.options.count; ++i) {
            AVMediaSelectionOption *currentOption = [group.options objectAtIndex:i];
            NSString *optionValue;
            if ([type isEqualToString:@"language"]) {
                optionValue = [currentOption extendedLanguageTag];
            } else {
                optionValue = [[[currentOption commonMetadata]
                                valueForKey:@"value"]
                               objectAtIndex:0];
            }
            if ([value isEqualToString:optionValue]) {
                mediaOption = currentOption;
                break;
            }
        }
        //} else if ([type isEqualToString:@"default"]) {
        //  option = group.defaultOption; */
    } else if ([type isEqualToString:@"index"]) {
        if ([criteria[@"value"] isKindOfClass:[NSNumber class]]) {
            int index = [criteria[@"value"] intValue];
            if (group.options.count > index) {
                mediaOption = [group.options objectAtIndex:index];
            }
        }
    } else { // default. invalid type or "system"
        [_player.currentItem selectMediaOptionAutomaticallyInMediaSelectionGroup:group];
        return;
    }
    
    // If a match isn't found, option will be nil and text tracks will be disabled
    [_player.currentItem selectMediaOption:mediaOption inMediaSelectionGroup:group];
}

- (void)setSelectedAudioTrack:(NSDictionary *)selectedAudioTrack {
    _selectedAudioTrack = selectedAudioTrack;
    [self setMediaSelectionTrackForCharacteristic:AVMediaCharacteristicAudible
                                        withCriteria:_selectedAudioTrack];
}

- (void)setSelectedTextTrack:(NSDictionary *)selectedTextTrack {
  _selectedTextTrack = selectedTextTrack;
  if (_textTracks) { // sideloaded text tracks
    [self setSideloadedText];
  } else { // text tracks included in the HLS playlist
    [self setMediaSelectionTrackForCharacteristic:AVMediaCharacteristicLegible
                                     withCriteria:_selectedTextTrack];
  }
}

- (void) setSideloadedText {
  NSString *type = _selectedTextTrack[@"type"];
  NSArray *textTracks = [self getTextTrackInfo];
  
  // The first few tracks will be audio & video track
  int firstTextIndex = 0;
  for (firstTextIndex = 0; firstTextIndex < _player.currentItem.tracks.count; ++firstTextIndex) {
    if ([_player.currentItem.tracks[firstTextIndex].assetTrack hasMediaCharacteristic:AVMediaCharacteristicLegible]) {
      break;
    }
  }
  
  int selectedTrackIndex = RCTVideoUnset;
  
  if ([type isEqualToString:@"disabled"]) {
    // Do nothing. We want to ensure option is nil
  } else if ([type isEqualToString:@"language"]) {
    NSString *selectedValue = _selectedTextTrack[@"value"];
    for (int i = 0; i < textTracks.count; ++i) {
      NSDictionary *currentTextTrack = [textTracks objectAtIndex:i];
      if ([selectedValue isEqualToString:currentTextTrack[@"language"]]) {
        selectedTrackIndex = i;
        break;
      }
    }
  } else if ([type isEqualToString:@"title"]) {
    NSString *selectedValue = _selectedTextTrack[@"value"];
    for (int i = 0; i < textTracks.count; ++i) {
      NSDictionary *currentTextTrack = [textTracks objectAtIndex:i];
      if ([selectedValue isEqualToString:currentTextTrack[@"title"]]) {
        selectedTrackIndex = i;
        break;
      }
    }
  } else if ([type isEqualToString:@"index"]) {
    if ([_selectedTextTrack[@"value"] isKindOfClass:[NSNumber class]]) {
      int index = [_selectedTextTrack[@"value"] intValue];
      if (textTracks.count > index) {
        selectedTrackIndex = index;
      }
    }
  }
  
  // in the situation that a selected text track is not available (eg. specifies a textTrack not available)
  if (![type isEqualToString:@"disabled"] && selectedTrackIndex == RCTVideoUnset) {
    CFArrayRef captioningMediaCharacteristics = MACaptionAppearanceCopyPreferredCaptioningMediaCharacteristics(kMACaptionAppearanceDomainUser);
    NSArray *captionSettings = (__bridge NSArray*)captioningMediaCharacteristics;
    if ([captionSettings containsObject:AVMediaCharacteristicTranscribesSpokenDialogForAccessibility]) {
      selectedTrackIndex = 0; // If we can't find a match, use the first available track
      NSString *systemLanguage = [[NSLocale preferredLanguages] firstObject];
      for (int i = 0; i < textTracks.count; ++i) {
        NSDictionary *currentTextTrack = [textTracks objectAtIndex:i];
        if ([systemLanguage isEqualToString:currentTextTrack[@"language"]]) {
          selectedTrackIndex = i;
          break;
        }
      }
    }
  }
    
  for (int i = firstTextIndex; i < _player.currentItem.tracks.count; ++i) {
    BOOL isEnabled = NO;
    if (selectedTrackIndex != RCTVideoUnset) {
      isEnabled = i == selectedTrackIndex + firstTextIndex;
    }
    [_player.currentItem.tracks[i] setEnabled:isEnabled];
  }
}

-(void) setStreamingText {
  NSString *type = _selectedTextTrack[@"type"];
  AVMediaSelectionGroup *group = [_player.currentItem.asset
                                  mediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicLegible];
  AVMediaSelectionOption *mediaOption;
  
  if ([type isEqualToString:@"disabled"]) {
    // Do nothing. We want to ensure option is nil
  } else if ([type isEqualToString:@"language"] || [type isEqualToString:@"title"]) {
    NSString *value = _selectedTextTrack[@"value"];
    for (int i = 0; i < group.options.count; ++i) {
      AVMediaSelectionOption *currentOption = [group.options objectAtIndex:i];
      NSString *optionValue;
      if ([type isEqualToString:@"language"]) {
        optionValue = [currentOption extendedLanguageTag];
      } else {
        optionValue = [[[currentOption commonMetadata]
                        valueForKey:@"value"]
                       objectAtIndex:0];
      }
      if ([value isEqualToString:optionValue]) {
        mediaOption = currentOption;
        break;
      }
    }
    //} else if ([type isEqualToString:@"default"]) {
    //  option = group.defaultOption; */
  } else if ([type isEqualToString:@"index"]) {
    if ([_selectedTextTrack[@"value"] isKindOfClass:[NSNumber class]]) {
      int index = [_selectedTextTrack[@"value"] intValue];
      if (group.options.count > index) {
        mediaOption = [group.options objectAtIndex:index];
      }
    }
  } else { // default. invalid type or "system"
    [_player.currentItem selectMediaOptionAutomaticallyInMediaSelectionGroup:group];
    return;
  }
  
  // If a match isn't found, option will be nil and text tracks will be disabled
  [_player.currentItem selectMediaOption:mediaOption inMediaSelectionGroup:group];
}

- (void)setTextTracks:(NSArray*) textTracks;
{
  _textTracks = textTracks;

  // in case textTracks was set after selectedTextTrack
  if (_selectedTextTrack) [self setSelectedTextTrack:_selectedTextTrack];
}

- (NSArray *)getAudioTrackInfo
{
    NSMutableArray *audioTracks = [[NSMutableArray alloc] init];
    AVMediaSelectionGroup *group = [_player.currentItem.asset
                                    mediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicAudible];
    for (int i = 0; i < group.options.count; ++i) {
        AVMediaSelectionOption *currentOption = [group.options objectAtIndex:i];
        NSString *title = @"";
        NSArray *values = [[currentOption commonMetadata] valueForKey:@"value"];
        if (values.count > 0) {
            title = [values objectAtIndex:0];
        }
        NSString *language = [currentOption extendedLanguageTag] ? [currentOption extendedLanguageTag] : @"";
        NSDictionary *audioTrack = @{
                                    @"index": [NSNumber numberWithInt:i],
                                    @"title": title,
                                    @"language": language
                                    };
        [audioTracks addObject:audioTrack];
    }
    return audioTracks;
}

- (NSArray *)getTextTrackInfo
{
  // if sideloaded, textTracks will already be set
  if (_textTracks) return _textTracks;
  
  // if streaming video, we extract the text tracks
  NSMutableArray *textTracks = [[NSMutableArray alloc] init];
  AVMediaSelectionGroup *group = [_player.currentItem.asset
                                  mediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicLegible];
  for (int i = 0; i < group.options.count; ++i) {
    AVMediaSelectionOption *currentOption = [group.options objectAtIndex:i];
    NSString *title = @"";
    NSArray *values = [[currentOption commonMetadata] valueForKey:@"value"];
    if (values.count > 0) {
      title = [values objectAtIndex:0];
    }
    NSString *language = [currentOption extendedLanguageTag] ? [currentOption extendedLanguageTag] : @"";
    NSDictionary *textTrack = @{
                                @"index": [NSNumber numberWithInt:i],
                                @"title": title,
                                @"language": language
                                };
    [textTracks addObject:textTrack];
  }
  return textTracks;
}

- (BOOL)getFullscreen
{
  return _fullscreenPlayerPresented;
}

- (void)setFullscreen:(BOOL)fullscreen
{
  if( fullscreen && !_fullscreenPlayerPresented )
  {
    // Ensure player view controller is not null
    if( !_playerViewController )
    {
      [self usePlayerViewController];
    }
    // Set presentation style to fullscreen
    [_playerViewController setModalPresentationStyle:UIModalPresentationFullScreen];
    
    // Find the nearest view controller
    UIViewController *viewController = [self firstAvailableUIViewController];
    if( !viewController )
    {
      UIWindow *keyWindow = [[UIApplication sharedApplication] keyWindow];
      viewController = keyWindow.rootViewController;
      if( viewController.childViewControllers.count > 0 )
      {
        viewController = viewController.childViewControllers.lastObject;
      }
    }
    if( viewController )
    {
      _presentingViewController = viewController;
      if(self.onVideoFullscreenPlayerWillPresent) {
        self.onVideoFullscreenPlayerWillPresent(@{@"target": self.reactTag});
      }
      [viewController presentViewController:_playerViewController animated:true completion:^{
        _playerViewController.showsPlaybackControls = YES;
        _fullscreenPlayerPresented = fullscreen;
        if(self.onVideoFullscreenPlayerDidPresent) {
          self.onVideoFullscreenPlayerDidPresent(@{@"target": self.reactTag});
        }
      }];
    }
  }
  else if ( !fullscreen && _fullscreenPlayerPresented )
  {
    [self videoPlayerViewControllerWillDismiss:_playerViewController];
    [_presentingViewController dismissViewControllerAnimated:true completion:^{
      [self videoPlayerViewControllerDidDismiss:_playerViewController];
    }];
  }
}

- (void)usePlayerViewController
{
  if( _player )
  {
    _playerViewController = [self createPlayerViewController:_player withPlayerItem:_playerItem];
    // to prevent video from being animated when resizeMode is 'cover'
    // resize mode must be set before subview is added
    [self setResizeMode:_resizeMode];
    [self addSubview:_playerViewController.view];
  }
}

- (void)usePlayerLayer
{
  if( _player )
  {
    _playerLayer = [AVPlayerLayer playerLayerWithPlayer:_player];
    _playerLayer.frame = self.bounds;
    _playerLayer.needsDisplayOnBoundsChange = YES;
    
    // to prevent video from being animated when resizeMode is 'cover'
    // resize mode must be set before layer is added
    [self setResizeMode:_resizeMode];
    [_playerLayer addObserver:self forKeyPath:readyForDisplayKeyPath options:NSKeyValueObservingOptionNew context:nil];
    _playerLayerObserverSet = YES;
    
    [self.layer addSublayer:_playerLayer];
    self.layer.needsDisplayOnBoundsChange = YES;
  }
}

- (void)setControls:(BOOL)controls
{
  if( _controls != controls || (!_playerLayer && !_playerViewController) )
  {
    _controls = controls;
    if( _controls )
    {
      [self removePlayerLayer];
      [self usePlayerViewController];
    }
    else
    {
      [_playerViewController.view removeFromSuperview];
      _playerViewController = nil;
      [self usePlayerLayer];
    }
  }
}

- (void)setProgressUpdateInterval:(float)progressUpdateInterval
{
  _progressUpdateInterval = progressUpdateInterval;

  if (_timeObserver) {
    [self removePlayerTimeObserver];
    [self addPlayerTimeObserver];
  }
}

- (void)removePlayerLayer
{
  [_playerLayer removeFromSuperlayer];
  if (_playerLayerObserverSet) {
    [_playerLayer removeObserver:self forKeyPath:readyForDisplayKeyPath];
    _playerLayerObserverSet = NO;
  }
  _playerLayer = nil;
}

#pragma mark - RCTVideoPlayerViewControllerDelegate

- (void)videoPlayerViewControllerWillDismiss:(AVPlayerViewController *)playerViewController
{
  if (_playerViewController == playerViewController && _fullscreenPlayerPresented && self.onVideoFullscreenPlayerWillDismiss)
  {
    self.onVideoFullscreenPlayerWillDismiss(@{@"target": self.reactTag});
  }
}

- (void)videoPlayerViewControllerDidDismiss:(AVPlayerViewController *)playerViewController
{
  if (_playerViewController == playerViewController && _fullscreenPlayerPresented)
  {
    _fullscreenPlayerPresented = false;
    _presentingViewController = nil;
    _playerViewController = nil;
    [self applyModifiers];
    if(self.onVideoFullscreenPlayerDidDismiss) {
      self.onVideoFullscreenPlayerDidDismiss(@{@"target": self.reactTag});
    }
  }
}

#pragma mark - React View Management

- (void)insertReactSubview:(UIView *)view atIndex:(NSInteger)atIndex
{
  // We are early in the game and somebody wants to set a subview.
  // That can only be in the context of playerViewController.
  if( !_controls && !_playerLayer && !_playerViewController )
  {
    [self setControls:true];
  }
  
  if( _controls )
  {
    view.frame = self.bounds;
    [_playerViewController.contentOverlayView insertSubview:view atIndex:atIndex];
  }
  else
  {
    RCTLogError(@"video cannot have any subviews");
  }
  return;
}

- (void)removeReactSubview:(UIView *)subview
{
  if( _controls )
  {
    [subview removeFromSuperview];
  }
  else
  {
    RCTLogError(@"video cannot have any subviews");
  }
  return;
}

- (void)layoutSubviews
{
  [super layoutSubviews];
  if( _controls )
  {
    _playerViewController.view.frame = self.bounds;
    
    // also adjust all subviews of contentOverlayView
    for (UIView* subview in _playerViewController.contentOverlayView.subviews) {
      subview.frame = self.bounds;
    }
  }
  else
  {
    [CATransaction begin];
    [CATransaction setAnimationDuration:0];
    _playerLayer.frame = self.bounds;
    [CATransaction commit];
  }
}

#pragma mark - Lifecycle

- (void)removeFromSuperview
{
  [_player pause];
  if (_playbackRateObserverRegistered) {
    [_player removeObserver:self forKeyPath:playbackRate context:nil];
    _playbackRateObserverRegistered = NO;
  }
  _player = nil;
  if (_adsManager) {
    [_adsManager destroy];
    _adsManager = nil;
  }
  
  [self removePlayerLayer];
  
  [_playerViewController.view removeFromSuperview];
  _playerViewController = nil;
  
  [self removePlayerTimeObserver];
  [self removePlayerItemObservers];
  
  _eventDispatcher = nil;
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  
  [super removeFromSuperview];
}

@end
