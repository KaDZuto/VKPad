#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>

#define THEME_BG          [UIColor colorWithRed:0.09 green:0.10 blue:0.12 alpha:1.0] /* #17191F */
#define THEME_SURFACE     [UIColor colorWithRed:0.13 green:0.14 blue:0.17 alpha:1.0] /* #21242B */
#define THEME_CARD        [UIColor colorWithRed:0.17 green:0.19 blue:0.23 alpha:1.0] /* #2B303B */
#define THEME_BLUE        [UIColor colorWithRed:0.18 green:0.53 blue:0.96 alpha:1.0] /* #2D88F3 VK Blue */
#define THEME_TEXT_WHITE  [UIColor colorWithWhite:0.95 alpha:1.0]
#define THEME_TEXT_MUTED  [UIColor colorWithWhite:0.62 alpha:1.0]
#define THEME_BORDER      [UIColor colorWithRed:0.24 green:0.26 blue:0.30 alpha:1.0]
#define THEME_ACTIVE      [UIColor colorWithRed:0.22 green:0.80 blue:0.45 alpha:1.0]

#define VK_API_VERSION    @"5.131"
// Kate Mobile Official Client ID (allows audio search & streaming without token ban)
#define KATE_CLIENT_ID    @"2685278"

// --- VK Token & Session Manager ---
@interface VKSession : NSObject
+ (instancetype)shared;
@property (nonatomic, strong) NSString *token;
@property (nonatomic, strong) NSString *userId;
@property (nonatomic, readonly) BOOL isAuthorized;
- (void)saveToken:(NSString *)tok userId:(NSString *)uid;
- (void)logout;
@end

@implementation VKSession
+ (instancetype)shared {
    static VKSession *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[VKSession alloc] init]; });
    return inst;
}
- (instancetype)init {
    if (self = [super init]) {
        _token = [[NSUserDefaults standardUserDefaults] stringForKey:@"VKPadToken"];
        _userId = [[NSUserDefaults standardUserDefaults] stringForKey:@"VKPadUserId"];
    }
    return self;
}
- (BOOL)isAuthorized {
    return self.token != nil && self.token.length > 5;
}
- (void)saveToken:(NSString *)tok userId:(NSString *)uid {
    _token = [tok stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    _userId = uid ? [uid stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"";
    [[NSUserDefaults standardUserDefaults] setObject:_token forKey:@"VKPadToken"];
    [[NSUserDefaults standardUserDefaults] setObject:_userId forKey:@"VKPadUserId"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}
- (void)logout {
    _token = nil;
    _userId = nil;
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"VKPadToken"];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"VKPadUserId"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}
@end

// --- Audio Player Manager with Background Playback ---
@interface AudioPlayerManager : NSObject
+ (instancetype)shared;
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) NSArray *playlist;
@property (nonatomic, assign) NSInteger currentIndex;
@property (nonatomic, assign) BOOL isPlaying;
@property (nonatomic, copy) void (^onTrackChanged)(NSDictionary *track);
@property (nonatomic, copy) void (^onPlaybackStatusChanged)(BOOL playing);
- (void)playPlaylist:(NSArray *)list startIndex:(NSInteger)idx;
- (void)togglePlayPause;
- (void)playNext;
- (void)playPrev;
- (NSDictionary *)currentTrack;
@end

@implementation AudioPlayerManager
+ (instancetype)shared {
    static AudioPlayerManager *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[AudioPlayerManager alloc] init]; });
    return inst;
}
- (instancetype)init {
    if (self = [super init]) {
        _playlist = @[];
        _currentIndex = -1;
        _isPlaying = NO;
        
        // Configure background audio session
        AVAudioSession *session = [AVAudioSession sharedInstance];
        NSError *err = nil;
        [session setCategory:AVAudioSessionCategoryPlayback error:&err];
        [session setActive:YES error:&err];
        
        // Remote Command Center (Lock Screen / Control Center)
        MPRemoteCommandCenter *cmdCenter = [MPRemoteCommandCenter sharedCommandCenter];
        [cmdCenter.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
            [self togglePlayPause];
            return MPRemoteCommandHandlerStatusSuccess;
        }];
        [cmdCenter.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
            [self togglePlayPause];
            return MPRemoteCommandHandlerStatusSuccess;
        }];
        [cmdCenter.nextTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
            [self playNext];
            return MPRemoteCommandHandlerStatusSuccess;
        }];
        [cmdCenter.previousTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
            [self playPrev];
            return MPRemoteCommandHandlerStatusSuccess;
        }];
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(itemDidFinishPlaying:) name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
    }
    return self;
}

- (NSDictionary *)currentTrack {
    if (_currentIndex >= 0 && _currentIndex < (NSInteger)_playlist.count) {
        return _playlist[_currentIndex];
    }
    return nil;
}

- (void)playPlaylist:(NSArray *)list startIndex:(NSInteger)idx {
    if (!list || list.count == 0) return;
    self.playlist = list;
    self.currentIndex = idx;
    [self playCurrentIndex];
}

- (void)playCurrentIndex {
    NSDictionary *track = [self currentTrack];
    if (!track) return;
    
    NSString *urlStr = track[@"url"];
    if (!urlStr || urlStr.length == 0) {
        NSLog(@"[AudioPlayer] Track has no URL, skipping...");
        [self playNext];
        return;
    }
    
    NSURL *u = [NSURL URLWithString:urlStr];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:u options:@{
        @"AVURLAssetHTTPHeaderFieldsKey": @{
            @"User-Agent": @"KateMobileAndroid/56 lite-arm64-v8a (Android 11; SDK 30; arm64-v8a; samsung SM-G988N; ru)"
        }
    }];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    
    if (!self.player) {
        self.player = [AVPlayer playerWithPlayerItem:item];
    } else {
        [self.player replaceCurrentItemWithPlayerItem:item];
    }
    
    [self.player play];
    self.isPlaying = YES;
    
    // Update Now Playing Info
    NSString *title = track[@"title"] ?: @"Аудиозапись";
    NSString *artist = track[@"artist"] ?: @"Исполнитель";
    NSInteger dur = [track[@"duration"] integerValue];
    
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[MPMediaItemPropertyTitle] = title;
    info[MPMediaItemPropertyArtist] = artist;
    if (dur > 0) info[MPMediaItemPropertyPlaybackDuration] = @(dur);
    info[MPNowPlayingInfoPropertyPlaybackRate] = @(1.0);
    [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:info];
    
    if (self.onTrackChanged) self.onTrackChanged(track);
    if (self.onPlaybackStatusChanged) self.onPlaybackStatusChanged(YES);
}

- (void)togglePlayPause {
    if (!self.player) return;
    if (self.isPlaying) {
        [self.player pause];
        self.isPlaying = NO;
    } else {
        [self.player play];
        self.isPlaying = YES;
    }
    if (self.onPlaybackStatusChanged) self.onPlaybackStatusChanged(self.isPlaying);
}

- (void)playNext {
    if (self.playlist.count == 0) return;
    self.currentIndex = (self.currentIndex + 1) % self.playlist.count;
    [self playCurrentIndex];
}

- (void)playPrev {
    if (self.playlist.count == 0) return;
    self.currentIndex = (self.currentIndex - 1 + self.playlist.count) % self.playlist.count;
    [self playCurrentIndex];
}

- (void)itemDidFinishPlaying:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self playNext];
    });
}
@end

// --- VK API Requester ---
@interface VKAPI : NSObject
+ (void)callMethod:(NSString *)method params:(NSDictionary *)params completion:(void(^)(id response, NSError *error))completion;
@end

@implementation VKAPI
+ (void)callMethod:(NSString *)method params:(NSDictionary *)params completion:(void(^)(id response, NSError *error))completion {
    NSMutableDictionary *p = [params ? [params mutableCopy] : [NSMutableDictionary dictionary] mutableCopy];
    p[@"v"] = VK_API_VERSION;
    NSString *token = [VKSession shared].token;
    if (token) p[@"access_token"] = token;
    
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *key in p) {
        NSString *val = [NSString stringWithFormat:@"%@", p[key]];
        NSString *enc = [val stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
        [parts addObject:[NSString stringWithFormat:@"%@=%@", key, enc]];
    }
    NSString *body = [parts componentsJoinedByString:@"&"];
    
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.vk.com/method/%@", method]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"KateMobileAndroid/56 lite-arm64-v8a (Android 11; SDK 30; arm64-v8a; samsung SM-G988N; ru)" forHTTPHeaderField:@"User-Agent"];
    
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (e || !d) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(nil, e);
            });
            return;
        }
        
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (json[@"error"]) {
                NSString *msg = json[@"error"][@"error_msg"] ?: @"Ошибка VK API";
                NSError *err = [NSError errorWithDomain:@"VK" code:[json[@"error"][@"error_code"] integerValue] userInfo:@{NSLocalizedDescriptionKey: msg}];
                if (completion) completion(nil, err);
            } else {
                if (completion) completion(json[@"response"], nil);
            }
        });
    }] resume];
}
@end

// --- OAuth Web View Controller ---
@interface VKOAuthViewController : UIViewController <WKNavigationDelegate>
@property (nonatomic, copy) void (^onSuccess)(NSString *token, NSString *userId);
@end

@implementation VKOAuthViewController {
    WKWebView *_webView;
    UIActivityIndicatorView *_spinner;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = THEME_BG;
    
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    
    // Top Bar
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 56)];
    bar.backgroundColor = THEME_SURFACE;
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:bar];
    
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(16, 10, 80, 36);
    [closeBtn setTitle:@"Отмена" forState:UIControlStateNormal];
    [closeBtn setTitleColor:THEME_BLUE forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [closeBtn addTarget:self action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:closeBtn];
    
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(100, 10, w - 200, 36)];
    title.textColor = THEME_TEXT_WHITE;
    title.textAlignment = NSTextAlignmentCenter;
    title.font = [UIFont boldSystemFontOfSize:17];
    title.text = @"Вход ВКонтакте";
    [bar addSubview:title];
    
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    _webView = [[WKWebView alloc] initWithFrame:CGRectMake(0, 56, w, h - 56) configuration:config];
    _webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _webView.navigationDelegate = self;
    [self.view addSubview:_webView];
    
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    _spinner.center = self.view.center;
    _spinner.hidesWhenStopped = YES;
    [self.view addSubview:_spinner];
    
    // Request Kate Mobile App ID with audio, wall, friends, messages, offline rights
    NSString *oauthUrl = [NSString stringWithFormat:
        @"https://oauth.vk.com/authorize?client_id=%@&scope=audio,wall,friends,messages,offline&redirect_uri=https://oauth.vk.com/blank.html&display=touch&response_type=token&v=%@",
        KATE_CLIENT_ID, VK_API_VERSION];
    
    NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:oauthUrl]];
    [_webView loadRequest:req];
    [_spinner startAnimating];
}

- (void)onClose {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [_spinner stopAnimating];
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSString *urlStr = action.request.URL.absoluteString;
    if ([urlStr containsString:@"blank.html#access_token="]) {
        NSString *fragment = [action.request.URL fragment];
        NSArray *pairs = [fragment componentsSeparatedByString:@"&"];
        NSString *token = nil;
        NSString *userId = nil;
        for (NSString *p in pairs) {
            NSArray *kv = [p componentsSeparatedByString:@"="];
            if (kv.count == 2) {
                if ([kv[0] isEqualToString:@"access_token"]) token = kv[1];
                if ([kv[0] isEqualToString:@"user_id"]) userId = kv[1];
            }
        }
        if (token) {
            decisionHandler(WKNavigationActionPolicyCancel);
            if (self.onSuccess) self.onSuccess(token, userId);
            [self dismissViewControllerAnimated:YES completion:nil];
            return;
        }
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}
@end

// --- Token Input Guide Dialog ---
@interface TokenGuideViewController : UIViewController
@property (nonatomic, copy) void (^onTokenEntered)(NSString *tok, NSString *uid);
@end

@implementation TokenGuideViewController {
    UITextField *_tokenField;
    UITextField *_userIdField;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = THEME_BG;
    
    CGFloat w = self.view.bounds.size.width;
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 56)];
    bar.backgroundColor = THEME_SURFACE;
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:bar];
    
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(16, 10, 80, 36);
    [closeBtn setTitle:@"Закрыть" forState:UIControlStateNormal];
    [closeBtn setTitleColor:THEME_BLUE forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [closeBtn addTarget:self action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:closeBtn];
    
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(100, 10, w - 200, 36)];
    title.textColor = THEME_TEXT_WHITE;
    title.textAlignment = NSTextAlignmentCenter;
    title.font = [UIFont boldSystemFontOfSize:17];
    title.text = @"Ввод токена VK / Kate Mobile";
    [bar addSubview:title];
    
    UIScrollView *sv = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 56, w, self.view.bounds.size.height - 56)];
    sv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:sv];
    
    UILabel *guide = [[UILabel alloc] initWithFrame:CGRectMake(24, 16, w - 48, 140)];
    guide.numberOfLines = 0;
    guide.textColor = THEME_TEXT_MUTED;
    guide.font = [UIFont systemFontOfSize:14];
    guide.text = @"🔑 Как получить токен Kate Mobile для доступа к VK Музыке:\n\n"
                 @"1. Перейдите в браузере по ссылке:\n   https://vkhost.github.io\n"
                 @"2. Выберите приложение «Kate Mobile» и нажмите «Получить».\n"
                 @"3. Разрешите доступ и скопируйте параметр access_token из адресной строки после перенаправления.\n"
                 @"4. Вставьте полученный токен в поле ниже:";
    [sv addSubview:guide];
    
    _tokenField = [[UITextField alloc] initWithFrame:CGRectMake(24, 170, w - 48, 44)];
    _tokenField.backgroundColor = THEME_SURFACE;
    _tokenField.textColor = THEME_TEXT_WHITE;
    _tokenField.layer.cornerRadius = 8;
    _tokenField.layer.borderColor = THEME_BORDER.CGColor;
    _tokenField.layer.borderWidth = 1.0;
    _tokenField.placeholder = @" Вставьте ваш VK access_token здесь...";
    _tokenField.font = [UIFont systemFontOfSize:14];
    _tokenField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _tokenField.autocorrectionType = UITextAutocorrectionTypeNo;
    [sv addSubview:_tokenField];
    
    _userIdField = [[UITextField alloc] initWithFrame:CGRectMake(24, 226, w - 48, 44)];
    _userIdField.backgroundColor = THEME_SURFACE;
    _userIdField.textColor = THEME_TEXT_WHITE;
    _userIdField.layer.cornerRadius = 8;
    _userIdField.layer.borderColor = THEME_BORDER.CGColor;
    _userIdField.layer.borderWidth = 1.0;
    _userIdField.placeholder = @" ID пользователя (необязательно, например 1234567)";
    _userIdField.font = [UIFont systemFontOfSize:14];
    _userIdField.keyboardType = UIKeyboardTypeNumberPad;
    [sv addSubview:_userIdField];
    
    UIButton *saveBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    saveBtn.frame = CGRectMake(24, 290, w - 48, 48);
    saveBtn.backgroundColor = THEME_BLUE;
    saveBtn.layer.cornerRadius = 8;
    [saveBtn setTitle:@"Сохранить токен и войти" forState:UIControlStateNormal];
    [saveBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    saveBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [saveBtn addTarget:self action:@selector(onSave) forControlEvents:UIControlEventTouchUpInside];
    [sv addSubview:saveBtn];
}
- (void)onClose {
    [self dismissViewControllerAnimated:YES completion:nil];
}
- (void)onSave {
    NSString *t = _tokenField.text;
    NSString *u = _userIdField.text;
    if (t.length < 10) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Ошибка" message:@"Пожалуйста, введите корректный токен access_token" preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    if (self.onTokenEntered) self.onTokenEntered(t, u);
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end

// --- Audio Track Cell ---
@interface AudioTrackCell : UITableViewCell
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *artistLabel;
@property (nonatomic, strong) UILabel *durationLabel;
@property (nonatomic, strong) UIImageView *playStateIcon;
@end

@implementation AudioTrackCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if (self = [super initWithStyle:style reuseIdentifier:reuseIdentifier]) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleGray;
        
        _playStateIcon = [[UIImageView alloc] initWithFrame:CGRectMake(16, 18, 22, 22)];
        _playStateIcon.contentMode = UIViewContentModeScaleAspectFit;
        [self.contentView addSubview:_playStateIcon];
        
        _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(52, 10, 500, 22)];
        _titleLabel.textColor = THEME_TEXT_WHITE;
        _titleLabel.font = [UIFont boldSystemFontOfSize:15];
        [self.contentView addSubview:_titleLabel];
        
        _artistLabel = [[UILabel alloc] initWithFrame:CGRectMake(52, 32, 500, 18)];
        _artistLabel.textColor = THEME_TEXT_MUTED;
        _artistLabel.font = [UIFont systemFontOfSize:13];
        [self.contentView addSubview:_artistLabel];
        
        _durationLabel = [[UILabel alloc] initWithFrame:CGRectMake(560, 20, 60, 20)];
        _durationLabel.textColor = THEME_TEXT_MUTED;
        _durationLabel.font = [UIFont systemFontOfSize:13];
        _durationLabel.textAlignment = NSTextAlignmentRight;
        [self.contentView addSubview:_durationLabel];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    _durationLabel.frame = CGRectMake(w - 76, 20, 60, 20);
    _titleLabel.frame = CGRectMake(52, 10, w - 136, 22);
    _artistLabel.frame = CGRectMake(52, 32, w - 136, 18);
}
@end

// --- Mini Player Bottom Bar ---
@interface MiniPlayerView : UIView
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *artistLabel;
@property (nonatomic, strong) UIButton *playPauseBtn;
@property (nonatomic, strong) UIButton *nextBtn;
@property (nonatomic, strong) UIButton *prevBtn;
@end

@implementation MiniPlayerView
- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = THEME_CARD;
        self.layer.borderColor = THEME_BORDER.CGColor;
        self.layer.borderWidth = 1.0;
        
        _prevBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        _prevBtn.frame = CGRectMake(16, 12, 38, 38);
        [_prevBtn setTitle:@"⏮" forState:UIControlStateNormal];
        [_prevBtn setTitleColor:THEME_TEXT_WHITE forState:UIControlStateNormal];
        _prevBtn.titleLabel.font = [UIFont systemFontOfSize:20];
        [_prevBtn addTarget:self action:@selector(onPrev) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_prevBtn];
        
        _playPauseBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        _playPauseBtn.frame = CGRectMake(60, 10, 42, 42);
        _playPauseBtn.backgroundColor = THEME_BLUE;
        _playPauseBtn.layer.cornerRadius = 21;
        [_playPauseBtn setTitle:@"▶" forState:UIControlStateNormal];
        [_playPauseBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        _playPauseBtn.titleLabel.font = [UIFont boldSystemFontOfSize:18];
        [_playPauseBtn addTarget:self action:@selector(onPlayPause) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_playPauseBtn];
        
        _nextBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        _nextBtn.frame = CGRectMake(110, 12, 38, 38);
        [_nextBtn setTitle:@"⏭" forState:UIControlStateNormal];
        [_nextBtn setTitleColor:THEME_TEXT_WHITE forState:UIControlStateNormal];
        _nextBtn.titleLabel.font = [UIFont systemFontOfSize:20];
        [_nextBtn addTarget:self action:@selector(onNext) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_nextBtn];
        
        _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(160, 11, frame.size.width - 180, 20)];
        _titleLabel.textColor = THEME_TEXT_WHITE;
        _titleLabel.font = [UIFont boldSystemFontOfSize:15];
        _titleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [self addSubview:_titleLabel];
        
        _artistLabel = [[UILabel alloc] initWithFrame:CGRectMake(160, 31, frame.size.width - 180, 18)];
        _artistLabel.textColor = THEME_TEXT_MUTED;
        _artistLabel.font = [UIFont systemFontOfSize:13];
        _artistLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [self addSubview:_artistLabel];
        
        [self updateWithTrack:[[AudioPlayerManager shared] currentTrack]];
        
        __weak typeof(self) weakSelf = self;
        [AudioPlayerManager shared].onTrackChanged = ^(NSDictionary *t) {
            [weakSelf updateWithTrack:t];
        };
        [AudioPlayerManager shared].onPlaybackStatusChanged = ^(BOOL playing) {
            [weakSelf.playPauseBtn setTitle:playing ? @"⏸" : @"▶" forState:UIControlStateNormal];
        };
    }
    return self;
}

- (void)updateWithTrack:(NSDictionary *)track {
    if (!track) {
        _titleLabel.text = @"Ничего не воспроизводится";
        _artistLabel.text = @"Выберите трек для запуска";
        [_playPauseBtn setTitle:@"▶" forState:UIControlStateNormal];
        return;
    }
    _titleLabel.text = track[@"title"] ?: @"Без названия";
    _artistLabel.text = track[@"artist"] ?: @"Неизвестный исполнитель";
    [_playPauseBtn setTitle:[AudioPlayerManager shared].isPlaying ? @"⏸" : @"▶" forState:UIControlStateNormal];
}

- (void)onPlayPause {
    [[AudioPlayerManager shared] togglePlayPause];
}
- (void)onNext {
    [[AudioPlayerManager shared] playNext];
}
- (void)onPrev {
    [[AudioPlayerManager shared] playPrev];
}
@end

// --- Music View Controller ---
@interface MusicViewController : UIViewController <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@end

@implementation MusicViewController {
    UITableView *_tableView;
    UISearchBar *_searchBar;
    UIActivityIndicatorView *_spinner;
    UISegmentedControl *_segControl;
    NSArray *_audioList;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = THEME_BG;
    
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    
    // Header
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 100)];
    header.backgroundColor = THEME_SURFACE;
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:header];
    
    _searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(16, 8, w - 32, 44)];
    _searchBar.placeholder = @"Поиск по VK Музыке (трек или артист)...";
    _searchBar.barTintColor = THEME_SURFACE;
    _searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _searchBar.delegate = self;
    [header addSubview:_searchBar];
    
    _segControl = [[UISegmentedControl alloc] initWithItems:@[@"Мои аудиозаписи", @"Рекомендации", @"Поиск"]];
    _segControl.frame = CGRectMake(16, 56, w - 32, 34);
    _segControl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _segControl.tintColor = THEME_BLUE;
    _segControl.selectedSegmentIndex = 0;
    [_segControl addTarget:self action:@selector(onSegmentChanged:) forControlEvents:UIControlEventValueChanged];
    [header addSubview:_segControl];
    
    _tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 100, w, h - 162) style:UITableViewStylePlain];
    _tableView.backgroundColor = THEME_BG;
    _tableView.separatorColor = THEME_BORDER;
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_tableView];
    
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    _spinner.center = self.view.center;
    _spinner.hidesWhenStopped = YES;
    [self.view addSubview:_spinner];
    
    MiniPlayerView *miniPlayer = [[MiniPlayerView alloc] initWithFrame:CGRectMake(0, h - 62, w, 62)];
    miniPlayer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    [self.view addSubview:miniPlayer];
    
    [self loadMyAudio];
}

- (void)onSegmentChanged:(UISegmentedControl *)sc {
    if (sc.selectedSegmentIndex == 0) {
        [self loadMyAudio];
    } else if (sc.selectedSegmentIndex == 1) {
        [self loadRecommendations];
    }
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    NSString *q = [searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (q.length == 0) return;
    _segControl.selectedSegmentIndex = 2;
    [self searchAudio:q];
}

- (void)loadMyAudio {
    [_spinner startAnimating];
    [VKAPI callMethod:@"audio.get" params:@{@"count": @100} completion:^(id response, NSError *error) {
        [self->_spinner stopAnimating];
        if (response && response[@"items"]) {
            self->_audioList = response[@"items"];
            [self->_tableView reloadData];
        } else if (error) {
            NSLog(@"[VKPad] audio.get error: %@", error.localizedDescription);
        }
    }];
}

- (void)loadRecommendations {
    [_spinner startAnimating];
    [VKAPI callMethod:@"audio.getRecommendations" params:@{@"count": @80} completion:^(id response, NSError *error) {
        [self->_spinner stopAnimating];
        if (response && response[@"items"]) {
            self->_audioList = response[@"items"];
            [self->_tableView reloadData];
        }
    }];
}

- (void)searchAudio:(NSString *)query {
    [_spinner startAnimating];
    [VKAPI callMethod:@"audio.search" params:@{@"q": query, @"count": @100, @"auto_complete": @1} completion:^(id response, NSError *error) {
        [self->_spinner stopAnimating];
        if (response && response[@"items"]) {
            self->_audioList = response[@"items"];
            [self->_tableView reloadData];
        }
    }];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _audioList.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 60.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"AudioCell";
    AudioTrackCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[AudioTrackCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
    }
    
    NSDictionary *track = _audioList[indexPath.row];
    cell.titleLabel.text = track[@"title"] ?: @"Без названия";
    cell.artistLabel.text = track[@"artist"] ?: @"Неизвестный исполнитель";
    
    NSInteger d = [track[@"duration"] integerValue];
    cell.durationLabel.text = [NSString stringWithFormat:@"%02ld:%02ld", (long)(d / 60), (long)(d % 60)];
    
    NSDictionary *cur = [[AudioPlayerManager shared] currentTrack];
    BOOL isThis = cur && [cur[@"id"] isEqual:track[@"id"]];
    
    if (isThis) {
        cell.backgroundColor = [UIColor colorWithRed:0.12 green:0.24 blue:0.18 alpha:0.8];
        cell.titleLabel.textColor = THEME_ACTIVE;
        cell.artistLabel.textColor = THEME_ACTIVE;
    } else {
        cell.backgroundColor = [UIColor clearColor];
        cell.titleLabel.textColor = THEME_TEXT_WHITE;
        cell.artistLabel.textColor = THEME_TEXT_MUTED;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [[AudioPlayerManager shared] playPlaylist:_audioList startIndex:indexPath.row];
    [tableView reloadData];
}
@end

// --- Feed (News) View Controller ---
@interface FeedViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@end

@implementation FeedViewController {
    UITableView *_tableView;
    UIActivityIndicatorView *_spinner;
    NSArray *_feedItems;
    NSMutableDictionary *_profiles;
    NSMutableDictionary *_groups;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = THEME_BG;
    
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    
    // Header
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 56)];
    bar.backgroundColor = THEME_SURFACE;
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:bar];
    
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 10, 200, 36)];
    title.textColor = THEME_TEXT_WHITE;
    title.font = [UIFont boldSystemFontOfSize:20];
    title.text = @"Новости VK";
    [bar addSubview:title];
    
    UIButton *refreshBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    refreshBtn.frame = CGRectMake(w - 110, 10, 96, 36);
    refreshBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [refreshBtn setTitle:@"Обновить" forState:UIControlStateNormal];
    [refreshBtn setTitleColor:THEME_BLUE forState:UIControlStateNormal];
    refreshBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [refreshBtn addTarget:self action:@selector(loadFeed) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:refreshBtn];
    
    _tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 56, w, h - 56) style:UITableViewStylePlain];
    _tableView.backgroundColor = THEME_BG;
    _tableView.separatorColor = THEME_BORDER;
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_tableView];
    
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    _spinner.center = self.view.center;
    _spinner.hidesWhenStopped = YES;
    [self.view addSubview:_spinner];
    
    [self loadFeed];
}

- (void)loadFeed {
    [_spinner startAnimating];
    [VKAPI callMethod:@"newsfeed.get" params:@{@"filters": @"post", @"count": @40} completion:^(id response, NSError *error) {
        [self->_spinner stopAnimating];
        if (response && response[@"items"]) {
            self->_feedItems = response[@"items"];
            
            // Map authors & communities
            self->_profiles = [NSMutableDictionary dictionary];
            for (NSDictionary *p in response[@"profiles"] ?: @[]) {
                self->_profiles[p[@"id"]] = [NSString stringWithFormat:@"%@ %@", p[@"first_name"], p[@"last_name"]];
            }
            self->_groups = [NSMutableDictionary dictionary];
            for (NSDictionary *g in response[@"groups"] ?: @[]) {
                self->_groups[g[@"id"]] = g[@"name"];
            }
            
            [self->_tableView reloadData];
        }
    }];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _feedItems.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 130.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"FeedCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.backgroundColor = THEME_CARD;
        cell.layer.borderColor = THEME_BORDER.CGColor;
        cell.layer.borderWidth = 0.5;
        cell.textLabel.textColor = THEME_BLUE;
        cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
        cell.detailTextLabel.textColor = THEME_TEXT_WHITE;
        cell.detailTextLabel.font = [UIFont systemFontOfSize:14];
        cell.detailTextLabel.numberOfLines = 4;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    
    NSDictionary *item = _feedItems[indexPath.row];
    NSInteger sourceId = [item[@"source_id"] integerValue];
    NSString *authorName = @"ВКонтакте";
    if (sourceId < 0) {
        authorName = _groups[@(-sourceId)] ?: @"Сообщество";
    } else {
        authorName = _profiles[@(sourceId)] ?: @"Пользователь";
    }
    
    cell.textLabel.text = authorName;
    NSString *postText = item[@"text"] ?: @"";
    if (postText.length == 0) {
        NSArray *att = item[@"attachments"];
        if (att.count > 0) postText = [NSString stringWithFormat:@"[Вложения: %lu шт.]", (unsigned long)att.count];
    }
    cell.detailTextLabel.text = postText;
    return cell;
}
@end

// --- Settings & Auth Controller ---
@interface SettingsViewController : UIViewController
@property (nonatomic, copy) void (^onAuthChanged)(void);
@end

@implementation SettingsViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = THEME_BG;
    
    CGFloat w = self.view.bounds.size.width;
    
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 56)];
    bar.backgroundColor = THEME_SURFACE;
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:bar];
    
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 10, w - 40, 36)];
    title.textColor = THEME_TEXT_WHITE;
    title.font = [UIFont boldSystemFontOfSize:18];
    title.text = @"Настройки аккаунта VK";
    [bar addSubview:title];
    
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(24, 80, w - 48, 300)];
    panel.backgroundColor = THEME_CARD;
    panel.layer.cornerRadius = 12;
    panel.layer.borderColor = THEME_BORDER.CGColor;
    panel.layer.borderWidth = 1.0;
    panel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:panel];
    
    BOOL isAuth = [VKSession shared].isAuthorized;
    
    UILabel *status = [[UILabel alloc] initWithFrame:CGRectMake(20, 20, panel.bounds.size.width - 40, 28)];
    status.textColor = isAuth ? THEME_ACTIVE : THEME_TEXT_WHITE;
    status.font = [UIFont boldSystemFontOfSize:16];
    status.text = isAuth ? @"✓ Авторизован в VK" : @"Вы не авторизованы";
    [panel addSubview:status];
    
    UIButton *oauthBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    oauthBtn.frame = CGRectMake(20, 64, panel.bounds.size.width - 40, 48);
    oauthBtn.backgroundColor = THEME_BLUE;
    oauthBtn.layer.cornerRadius = 8;
    [oauthBtn setTitle:@"Вход через ВКонтакте (OAuth)" forState:UIControlStateNormal];
    [oauthBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    oauthBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [oauthBtn addTarget:self action:@selector(openOAuth) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:oauthBtn];
    
    UIButton *tokenBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    tokenBtn.frame = CGRectMake(20, 124, panel.bounds.size.width - 40, 48);
    tokenBtn.backgroundColor = THEME_SURFACE;
    tokenBtn.layer.cornerRadius = 8;
    tokenBtn.layer.borderColor = THEME_BORDER.CGColor;
    tokenBtn.layer.borderWidth = 1.0;
    [tokenBtn setTitle:@"Ввести Kate Mobile токен вручную" forState:UIControlStateNormal];
    [tokenBtn setTitleColor:THEME_TEXT_WHITE forState:UIControlStateNormal];
    tokenBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [tokenBtn addTarget:self action:@selector(openTokenGuide) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:tokenBtn];
    
    if (isAuth) {
        UIButton *logoutBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        logoutBtn.frame = CGRectMake(20, 184, panel.bounds.size.width - 40, 48);
        logoutBtn.backgroundColor = [UIColor colorWithRed:0.80 green:0.20 blue:0.25 alpha:1.0];
        logoutBtn.layer.cornerRadius = 8;
        [logoutBtn setTitle:@"Выйти из аккаунта" forState:UIControlStateNormal];
        [logoutBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        logoutBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
        [logoutBtn addTarget:self action:@selector(onLogout) forControlEvents:UIControlEventTouchUpInside];
        [panel addSubview:logoutBtn];
    }
}

- (void)openOAuth {
    VKOAuthViewController *vc = [[VKOAuthViewController alloc] init];
    vc.onSuccess = ^(NSString *tok, NSString *uid) {
        [[VKSession shared] saveToken:tok userId:uid];
        if (self.onAuthChanged) self.onAuthChanged();
    };
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)openTokenGuide {
    TokenGuideViewController *vc = [[TokenGuideViewController alloc] init];
    vc.onTokenEntered = ^(NSString *tok, NSString *uid) {
        [[VKSession shared] saveToken:tok userId:uid];
        if (self.onAuthChanged) self.onAuthChanged();
    };
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)onLogout {
    [[VKSession shared] logout];
    if (self.onAuthChanged) self.onAuthChanged();
}
@end

// --- Root Tab Bar Controller ---
@interface MainTabBarController : UITabBarController
@end

@implementation MainTabBarController
- (void)viewDidLoad {
    [super viewDidLoad];
    [self setupControllers];
}

- (void)setupControllers {
    MusicViewController *musicVC = [[MusicViewController alloc] init];
    musicVC.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"VK Музыка" image:nil tag:0];
    
    FeedViewController *feedVC = [[FeedViewController alloc] init];
    feedVC.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Новости" image:nil tag:1];
    
    SettingsViewController *settingsVC = [[SettingsViewController alloc] init];
    settingsVC.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Настройки / Вход" image:nil tag:2];
    
    __weak typeof(self) weakSelf = self;
    settingsVC.onAuthChanged = ^{
        [weakSelf setupControllers];
    };
    
    self.viewControllers = @[musicVC, feedVC, settingsVC];
    self.tabBar.barTintColor = THEME_SURFACE;
    self.tabBar.tintColor = THEME_BLUE;
}
@end

// --- Application Delegate ---
@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.rootViewController = [[MainTabBarController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char * argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
