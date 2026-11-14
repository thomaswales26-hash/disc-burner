#import <AVFoundation/AVFoundation.h>
#import <Cocoa/Cocoa.h>
#import <mach-o/dyld.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <string>
#include <vector>
#include <unistd.h>
#include <signal.h>

namespace fs = std::filesystem;

namespace
{
NSString* const kLastStreamURLKey = @"HappyHardcoreRadioLastStreamURL";

std::string resolveFFmpeg()
{
    std::vector<char> executablePath(4096);
    uint32_t pathSize = static_cast<uint32_t>(executablePath.size());
    if (_NSGetExecutablePath(executablePath.data(), &pathSize) == 0)
    {
        std::error_code error;
        const fs::path executable = fs::canonical(executablePath.data(), error);
        if (!error)
        {
            const fs::path contents = executable.parent_path().parent_path();
            const std::vector<fs::path> bundledPaths = {
                contents / "Resources" / "ffmpeg",
                contents / "Resources" / "libexec" / "happy-hardcore-radio" / "ffmpeg"
            };
            for (const auto& candidate : bundledPaths)
            {
                if (access(candidate.c_str(), X_OK) == 0)
                    return candidate.string();
            }
        }
    }

    const char* path = std::getenv("PATH");
    if (path == nullptr)
        return {};
    std::string directories(path);
    std::size_t start = 0;
    while (start <= directories.size())
    {
        const auto end = directories.find(':', start);
        const std::string directory =
            directories.substr(start, end == std::string::npos ? end : end - start);
        const fs::path candidate = fs::path(directory) / "ffmpeg";
        if (access(candidate.c_str(), X_OK) == 0)
            return candidate.string();
        if (end == std::string::npos)
            break;
        start = end + 1;
    }
    return {};
}

NSButton* makeButton(NSString* title, id target, SEL action)
{
    NSButton* button = [NSButton buttonWithTitle:title target:target action:action];
    button.bezelStyle = NSBezelStyleRounded;
    return button;
}

NSStackView* stack(NSArray<NSView*>* views, NSUserInterfaceLayoutOrientation orientation, CGFloat spacing)
{
    NSStackView* result = [NSStackView stackViewWithViews:views];
    result.orientation = orientation;
    result.alignment = orientation == NSUserInterfaceLayoutOrientationVertical
        ? NSLayoutAttributeLeading : NSLayoutAttributeCenterY;
    result.distribution = NSStackViewDistributionFill;
    result.spacing = spacing;
    return result;
}
}

@interface HappyHardcoreRadioDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
{
    NSWindow* _window;
    NSTextField* _urlField;
    NSTextField* _playbackStatus;
    NSTextField* _recordStatus;
    NSTextView* _logView;
    NSButton* _playButton;
    NSButton* _recordButton;
    NSSlider* _volumeSlider;
    AVPlayer* _player;
    NSTask* _recordingTask;
    NSPipe* _recordingPipe;
    BOOL _stoppingRecording;
}
- (void)togglePlayback:(id)sender;
- (void)toggleRecording:(id)sender;
- (void)changeVolume:(id)sender;
@end

@implementation HappyHardcoreRadioDelegate

- (void)applicationDidFinishLaunching:(NSNotification*)notification
{
    (void)notification;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

    NSMenu* menuBar = [[NSMenu alloc] init];
    NSMenuItem* appMenuItem = [[NSMenuItem alloc] init];
    [menuBar addItem:appMenuItem];
    NSMenu* appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"Quit Happy Hardcore Radio"
                       action:@selector(terminate:)
                keyEquivalent:@"q"];
    appMenuItem.submenu = appMenu;
    NSApp.mainMenu = menuBar;

    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 760, 650)
                                          styleMask:NSWindowStyleMaskTitled |
                                                    NSWindowStyleMaskClosable |
                                                    NSWindowStyleMaskMiniaturizable |
                                                    NSWindowStyleMaskResizable
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _window.title = @"Happy Hardcore Radio";
    _window.minSize = NSMakeSize(600, 540);
    _window.delegate = self;
    NSView* content = _window.contentView;

    NSTextField* eyebrow = [NSTextField labelWithString:@"HAPPY HARDCORE  /  LIVE RADIO"];
    eyebrow.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightBold];
    eyebrow.textColor = [NSColor colorWithCalibratedRed:0.96 green:0.39 blue:0.72 alpha:1];
    NSTextField* title = [NSTextField labelWithString:@"Turn it up."];
    title.font = [NSFont systemFontOfSize:36 weight:NSFontWeightHeavy];
    NSTextField* subtitle = [NSTextField labelWithString:
        @"Paste a station stream URL, hit play, and capture the mix with FFmpeg."];
    subtitle.textColor = NSColor.secondaryLabelColor;

    NSTextField* streamLabel = [NSTextField labelWithString:@"STREAM URL"];
    streamLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    _urlField = [[NSTextField alloc] init];
    _urlField.placeholderString = @"https://your-station.example/live";
    _urlField.stringValue = [[NSUserDefaults standardUserDefaults] stringForKey:kLastStreamURLKey] ?: @"";
    _urlField.toolTip = @"Enter an HTTP(S) radio stream URL.";
    [_urlField.widthAnchor constraintGreaterThanOrEqualToConstant:380].active = YES;
    _playButton = makeButton(@"Play", self, @selector(togglePlayback:));
    [_playButton setKeyEquivalent:@" "];
    NSStackView* streamRow = stack(@[_urlField, _playButton],
                                  NSUserInterfaceLayoutOrientationHorizontal, 10);

    _playbackStatus = [NSTextField labelWithString:@"READY TO RAVE"];
    _playbackStatus.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightSemibold];
    _playbackStatus.textColor = NSColor.secondaryLabelColor;
    NSTextField* volumeLabel = [NSTextField labelWithString:@"VOLUME"];
    volumeLabel.font = [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold];
    _volumeSlider = [[NSSlider alloc] init];
    _volumeSlider.minValue = 0;
    _volumeSlider.maxValue = 1;
    _volumeSlider.doubleValue = 0.8;
    _volumeSlider.target = self;
    _volumeSlider.action = @selector(changeVolume:);
    [_volumeSlider.widthAnchor constraintEqualToConstant:130].active = YES;
    NSStackView* volumeRow = stack(@[volumeLabel, _volumeSlider],
                                  NSUserInterfaceLayoutOrientationHorizontal, 8);
    NSStackView* playbackRow = stack(@[_playbackStatus, volumeRow],
                                    NSUserInterfaceLayoutOrientationHorizontal, 16);

    _recordButton = makeButton(@"Record stream…", self, @selector(toggleRecording:));
    _recordStatus = [NSTextField labelWithString:@"Recorder ready"];
    _recordStatus.textColor = NSColor.secondaryLabelColor;
    NSStackView* recordRow = stack(@[_recordButton, _recordStatus],
                                  NSUserInterfaceLayoutOrientationHorizontal, 12);

    NSTextField* activityHeading = [NSTextField labelWithString:@"SESSION"];
    activityHeading.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    _logView = [[NSTextView alloc] init];
    _logView.editable = NO;
    _logView.selectable = YES;
    _logView.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    _logView.textContainerInset = NSMakeSize(10, 10);
    NSScrollView* logScroll = [[NSScrollView alloc] init];
    logScroll.hasVerticalScroller = YES;
    logScroll.borderType = NSBezelBorder;
    logScroll.documentView = _logView;
    [logScroll.heightAnchor constraintGreaterThanOrEqualToConstant:140].active = YES;

    NSTextField* footer = [NSTextField labelWithString:
        @"Use streams you are authorized to listen to and record."];
    footer.font = [NSFont systemFontOfSize:11];
    footer.textColor = NSColor.tertiaryLabelColor;
    NSView* spacer = [[NSView alloc] init];
    NSStackView* root = stack(@[
        eyebrow, title, subtitle, streamLabel, streamRow, playbackRow, recordRow,
        activityHeading, logScroll, footer, spacer
    ], NSUserInterfaceLayoutOrientationVertical, 14);
    root.translatesAutoresizingMaskIntoConstraints = NO;
    root.edgeInsets = NSEdgeInsetsMake(28, 30, 22, 30);
    [content addSubview:root];
    [NSLayoutConstraint activateConstraints:@[
        [root.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [root.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [root.topAnchor constraintEqualToAnchor:content.topAnchor],
        [root.bottomAnchor constraintEqualToAnchor:content.bottomAnchor]
    ]];
    [logScroll setContentHuggingPriority:NSLayoutPriorityDefaultLow
                                 forOrientation:NSLayoutConstraintOrientationVertical];
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow
                               forOrientation:NSLayoutConstraintOrientationVertical];

    _player = [[AVPlayer alloc] init];
    _player.volume = static_cast<float>(_volumeSlider.doubleValue);
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playerFailed:)
                                                 name:AVPlayerItemFailedToPlayToEndTimeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playerStarted:)
                                                 name:AVPlayerItemNewAccessLogEntryNotification
                                               object:nil];
    [self appendLog:@"Ready. Enter an HTTP(S) station stream URL to start listening.\n"];
    [_window center];
    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)windowShouldClose:(id)sender
{
    (void)sender;
    return _recordingTask == nil;
}

- (void)applicationWillTerminate:(NSNotification*)notification
{
    (void)notification;
    if (_recordingTask != nil)
        kill(_recordingTask.processIdentifier, SIGINT);
    [_player pause];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)appendLog:(NSString*)message
{
    if (message.length == 0)
        return;
    [_logView.textStorage appendAttributedString:[[NSAttributedString alloc]
        initWithString:message attributes:@{
            NSFontAttributeName: _logView.font,
            NSForegroundColorAttributeName: NSColor.labelColor
        }]];
    [_logView scrollRangeToVisible:NSMakeRange(_logView.string.length, 0)];
}

- (BOOL)streamURL:(NSURL**)result
{
    NSString* text = [_urlField.stringValue stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSURLComponents* components = [NSURLComponents componentsWithString:text];
    if (components == nil ||
        !([components.scheme.lowercaseString isEqualToString:@"http"] ||
          [components.scheme.lowercaseString isEqualToString:@"https"]) ||
        components.host.length == 0)
    {
        [self showMessage:@"Enter a valid HTTP or HTTPS station stream URL."];
        return NO;
    }
    *result = components.URL;
    [[NSUserDefaults standardUserDefaults] setObject:text forKey:kLastStreamURLKey];
    return YES;
}

- (void)togglePlayback:(id)sender
{
    (void)sender;
    if (_playButton.title.length > 0 && [_playButton.title isEqualToString:@"Pause"])
    {
        [_player pause];
        _playButton.title = @"Play";
        _playbackStatus.stringValue = @"PAUSED";
        [self appendLog:@"Playback paused.\n"];
        return;
    }

    NSURL* url = nil;
    if (![self streamURL:&url])
        return;
    [_player replaceCurrentItemWithPlayerItem:[AVPlayerItem playerItemWithURL:url]];
    _player.volume = static_cast<float>(_volumeSlider.doubleValue);
    [_player play];
    _playButton.title = @"Pause";
    _playbackStatus.stringValue = @"TUNING IN…";
    [self appendLog:[NSString stringWithFormat:@"Playing %@\n", url.absoluteString]];
}

- (void)changeVolume:(id)sender
{
    (void)sender;
    _player.volume = static_cast<float>(_volumeSlider.doubleValue);
}

- (void)toggleRecording:(id)sender
{
    (void)sender;
    if (_recordingTask != nil)
    {
        _stoppingRecording = YES;
        _recordButton.enabled = NO;
        _recordStatus.stringValue = @"Finishing recording…";
        [self appendLog:@"Stopping recorder and finalizing the audio file…\n"];
        if (kill(_recordingTask.processIdentifier, SIGINT) != 0)
        {
            _recordButton.enabled = YES;
            _recordStatus.stringValue = @"Could not stop recorder";
            [self appendLog:[NSString stringWithFormat:@"Could not signal FFmpeg: %s\n", strerror(errno)]];
        }
        return;
    }

    NSURL* url = nil;
    if (![self streamURL:&url])
        return;
    const std::string ffmpeg = resolveFFmpeg();
    if (ffmpeg.empty())
    {
        [self showMessage:@"FFmpeg was not found. Install FFmpeg (for example, with `brew install ffmpeg`) or add it to PATH, then try again."];
        return;
    }

    NSSavePanel* panel = [NSSavePanel savePanel];
    panel.title = @"Save stream recording";
    panel.nameFieldStringValue = @"Happy Hardcore Radio.m4a";
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"m4a"]];
    panel.canCreateDirectories = YES;
    if ([panel runModal] != NSModalResponseOK)
        return;
    const fs::path output(panel.URL.path.fileSystemRepresentation);
    if (fs::exists(output))
    {
        [self showMessage:@"That recording already exists. Choose a new filename; existing files are not overwritten."];
        return;
    }

    _recordingTask = [[NSTask alloc] init];
    _recordingTask.executableURL = [NSURL fileURLWithPath:
        [NSString stringWithUTF8String:ffmpeg.c_str()]];
    _recordingTask.arguments = @[
        @"-nostdin", @"-hide_banner", @"-loglevel", @"warning", @"-i", url.absoluteString,
        @"-vn", @"-c:a", @"aac", @"-b:a", @"192k", @"-f", @"ipod", @"-n",
        [NSString stringWithUTF8String:output.string().c_str()]
    ];
    _recordingPipe = [NSPipe pipe];
    _recordingTask.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    _recordingTask.standardError = _recordingPipe;
    _stoppingRecording = NO;
    HappyHardcoreRadioDelegate* delegate = self;
    _recordingTask.terminationHandler = ^(NSTask* task) {
        const int status = task.terminationStatus;
        dispatch_async(dispatch_get_main_queue(), ^{
            const BOOL wasStopping = delegate->_stoppingRecording;
            std::error_code fileError;
            const bool outputSaved = fs::is_regular_file(output, fileError) &&
                !fileError && fs::file_size(output, fileError) > 0 && !fileError;
            delegate->_recordingTask = nil;
            delegate->_recordingPipe = nil;
            delegate->_recordButton.enabled = YES;
            delegate->_recordButton.title = @"Record stream…";
            if (outputSaved && (status == 0 || wasStopping))
            {
                delegate->_recordStatus.stringValue = @"Recording saved";
                [delegate appendLog:[NSString stringWithFormat:@"Recording saved to %@\n",
                    [NSString stringWithUTF8String:output.string().c_str()]]];
            }
            else
            {
                delegate->_recordStatus.stringValue = @"Recording failed";
                [delegate appendLog:[NSString stringWithFormat:
                    @"FFmpeg stopped with status %d. Check the FFmpeg output above and confirm the stream is reachable.\n",
                    status]];
            }
        });
    };

    NSError* error = nil;
    if (![_recordingTask launchAndReturnError:&error])
    {
        _recordingTask = nil;
        _recordingPipe = nil;
        [self showMessage:[NSString stringWithFormat:@"Could not start FFmpeg: %@",
            error.localizedDescription ?: @"unknown launch error"]];
        return;
    }
    _recordButton.title = @"Stop recording";
    _recordStatus.stringValue = @"Recording live stream";
    [self appendLog:[NSString stringWithFormat:@"Recording %@ to %@\n",
        url.absoluteString, [NSString stringWithUTF8String:output.string().c_str()]]];

    NSFileHandle* reader = _recordingPipe.fileHandleForReading;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        while (true)
        {
            NSData* data = [reader readDataOfLength:4096];
            if (data.length == 0)
                break;
            NSString* text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (text == nil)
                text = @"(FFmpeg emitted non-text output)\n";
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendLog:text];
            });
        }
    });
}

- (void)playerFailed:(NSNotification*)notification
{
    AVPlayerItem* item = notification.object;
    if (item != _player.currentItem)
        return;
    NSError* error = notification.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
    _playButton.title = @"Play";
    _playbackStatus.stringValue = @"STREAM ERROR";
    [self appendLog:[NSString stringWithFormat:@"Playback failed: %@\n",
        error.localizedDescription ?: @"The station stream could not be played."]];
}

- (void)playerStarted:(NSNotification*)notification
{
    if (notification.object == _player.currentItem && [_playButton.title isEqualToString:@"Pause"])
        _playbackStatus.stringValue = @"ON AIR";
}

- (void)showMessage:(NSString*)message
{
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"Happy Hardcore Radio";
    alert.informativeText = message;
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

@end

int main()
{
    @autoreleasepool
    {
        NSApplication* application = [NSApplication sharedApplication];
        HappyHardcoreRadioDelegate* delegate = [[HappyHardcoreRadioDelegate alloc] init];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
