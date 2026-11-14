#import <Cocoa/Cocoa.h>
#import <mach-o/dyld.h>

#include <cerrno>
#include <cstdlib>
#include <filesystem>
#include <sstream>
#include <string>
#include <string_view>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

namespace fs = std::filesystem;

namespace
{
fs::path bundledTool(const std::string& name)
{
    std::vector<char> executablePath(4096);
    uint32_t pathSize = static_cast<uint32_t>(executablePath.size());
    if (_NSGetExecutablePath(executablePath.data(), &pathSize) != 0)
        return {};

    std::error_code error;
    const fs::path executable = fs::canonical(executablePath.data(), error);
    if (error)
        return {};

    const fs::path contents = executable.parent_path().parent_path();
    const fs::path bundled = contents / "Resources" / "libexec" / "disc-burner" / name;
    return access(bundled.c_str(), X_OK) == 0 ? bundled : fs::path{};
}

std::string resolveTool(const std::string& name)
{
    const fs::path bundled = bundledTool(name);
    if (!bundled.empty())
        return bundled.string();

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
        const fs::path candidate = fs::path(directory) / name;
        if (access(candidate.c_str(), X_OK) == 0)
            return candidate.string();
        if (end == std::string::npos)
            break;
        start = end + 1;
    }
    return {};
}

NSString* stringFromPath(const fs::path& path)
{
    return [NSString stringWithUTF8String:path.string().c_str()];
}

struct CommandResult
{
    int status;
    std::string output;
};

struct DriveDevice
{
    std::string identifier;
    std::string description;
};

CommandResult execute(const std::vector<std::string>& arguments)
{
    if (arguments.empty())
        return {1, "No command was provided.\n"};

    @autoreleasepool
    {
        NSTask* task = [[NSTask alloc] init];
        NSMutableArray<NSString*>* taskArguments = [NSMutableArray array];
        for (std::size_t index = 1; index < arguments.size(); ++index)
        {
            [taskArguments addObject:[NSString stringWithUTF8String:arguments[index].c_str()]];
        }

        task.executableURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:arguments.front().c_str()]];
        task.arguments = taskArguments;
        NSPipe* pipe = [NSPipe pipe];
        task.standardOutput = pipe;
        task.standardError = pipe;

        NSError* error = nil;
        if (![task launchAndReturnError:&error])
        {
            const std::string reason = error.localizedDescription.UTF8String
                ? error.localizedDescription.UTF8String
                : "unknown launch error";
            return {1, "Could not start " + arguments.front() + ": " + reason + "\n"};
        }

        NSData* data = [[pipe fileHandleForReading] readDataToEndOfFile];
        [task waitUntilExit];
        NSString* output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        std::string text = output.UTF8String ? output.UTF8String : "(command output was not UTF-8)\n";
        return {task.terminationStatus, std::move(text)};
    }
}

std::vector<DriveDevice> discoverCdrdaoDrives(std::string& diagnostic)
{
    const std::string cdrdao = resolveTool("cdrdao");
    if (cdrdao.empty())
    {
        diagnostic = "cdrdao is unavailable.";
        return {};
    }

    const CommandResult result = execute({cdrdao, "scanbus"});
    diagnostic = result.output;
    std::vector<DriveDevice> drives;
    std::istringstream lines(result.output);
    std::string line;
    while (std::getline(lines, line))
    {
        const auto marker = line.find(" : ");
        if (marker == std::string::npos)
            continue;

        DriveDevice drive{line.substr(0, marker), line.substr(marker + 3)};
        if (drive.identifier.starts_with("IOService:") && !drive.description.empty())
            drives.push_back(std::move(drive));
    }
    if (result.status != 0 && diagnostic.empty())
        diagnostic = "cdrdao scanbus failed.\n";
    return drives;
}

NSString* driveDiscoveryFailure(std::string_view reason, const std::string& scanOutput)
{
    const CommandResult macOSDrives = execute({"/usr/bin/drutil", "list"});
    return [NSString stringWithFormat:
        @"%s\n\nmacOS optical drives:\n%s\ncdrdao scanbus:\n%s\n"
         "If media is inserted, eject it and scan again; a mounted disc can prevent cdrdao from accessing the drive.",
        std::string(reason).c_str(), macOSDrives.output.c_str(), scanOutput.c_str()];
}

NSButton* makeButton(NSString* title, id target, SEL action)
{
    NSButton* button = [NSButton buttonWithTitle:title target:target action:action];
    button.bezelStyle = NSBezelStyleRounded;
    return button;
}

NSStackView* verticalStack(NSArray<NSView*>* views, CGFloat spacing)
{
    NSStackView* stack = [NSStackView stackViewWithViews:views];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.distribution = NSStackViewDistributionFill;
    stack.spacing = spacing;
    return stack;
}

NSStackView* horizontalStack(NSArray<NSView*>* views, CGFloat spacing)
{
    NSStackView* stack = [NSStackView stackViewWithViews:views];
    stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stack.alignment = NSLayoutAttributeCenterY;
    stack.distribution = NSStackViewDistributionFill;
    stack.spacing = spacing;
    return stack;
}
}

@interface DiscBurnerAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
{
    NSWindow* _window;
    NSTextView* _logView;
    NSTextField* _statusLabel;
    NSProgressIndicator* _progress;
    NSPopUpButton* _discType;
    NSMutableArray<NSButton*>* _actionButtons;
    BOOL _operationRunning;
}
- (void)createDataDisc:(id)sender;
- (void)createDmg:(id)sender;
- (void)burnImage:(id)sender;
- (void)burnCue:(id)sender;
- (void)copyDisc:(id)sender;
- (void)listDrives:(id)sender;
- (void)showDriveStatus:(id)sender;
- (void)ejectDisc:(id)sender;
- (void)scanCdrdaoDevices:(id)sender;
@end

@implementation DiscBurnerAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification*)notification
{
    (void)notification;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

    NSMenu* menuBar = [[NSMenu alloc] init];
    NSMenuItem* appMenuItem = [[NSMenuItem alloc] init];
    [menuBar addItem:appMenuItem];
    NSMenu* appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"Quit Disc Burner"
                       action:@selector(terminate:)
                keyEquivalent:@"q"];
    appMenuItem.submenu = appMenu;
    NSApp.mainMenu = menuBar;

    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 820, 760)
                                          styleMask:NSWindowStyleMaskTitled |
                                                    NSWindowStyleMaskClosable |
                                                    NSWindowStyleMaskMiniaturizable |
                                                    NSWindowStyleMaskResizable
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _window.title = @"Disc Burner";
    _window.minSize = NSMakeSize(700, 640);
    _window.delegate = self;

    NSView* content = _window.contentView;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    _actionButtons = [NSMutableArray array];

    NSTextField* title = [NSTextField labelWithString:@"Disc Burner"];
    title.font = [NSFont systemFontOfSize:28 weight:NSFontWeightBold];
    NSTextField* subtitle = [NSTextField labelWithString:
        @"Create disk images, burn optical media, or import a CUE sheet for an audio CD."];
    subtitle.textColor = NSColor.secondaryLabelColor;

    NSButton* dataButton = makeButton(@"Create & Burn Data Disc", self, @selector(createDataDisc:));
    NSButton* dmgButton = makeButton(@"Create Compressed DMG", self, @selector(createDmg:));
    NSButton* imageButton = makeButton(@"Burn Disc Image…", self, @selector(burnImage:));
    NSButton* cueButton = makeButton(@"Burn Audio CD from CUE…", self, @selector(burnCue:));
    NSButton* copyButton = makeButton(@"Copy CD…", self, @selector(copyDisc:));
    _discType = [[NSPopUpButton alloc] init];
    [_discType addItemsWithTitles:@[@"Blu-ray", @"DVD", @"CD"]];
    _discType.toolTip = @"Data disc format";
    [dataButton setKeyEquivalent:@"\r"];
    [_actionButtons addObjectsFromArray:@[dataButton, dmgButton, imageButton, cueButton, copyButton]];

    NSTextField* discTypeLabel = [NSTextField labelWithString:@"Format:"];
    NSStackView* imageActions = horizontalStack(@[discTypeLabel, _discType, dataButton, dmgButton, imageButton], 10);
    NSStackView* cueActions = horizontalStack(@[cueButton, copyButton], 10);
    NSStackView* mediaSection = verticalStack(@[
        [NSTextField labelWithString:@"Create and burn"],
        imageActions,
        cueActions
    ], 10);

    NSButton* listButton = makeButton(@"List Drives", self, @selector(listDrives:));
    NSButton* statusButton = makeButton(@"Drive & Media Status", self, @selector(showDriveStatus:));
    NSButton* ejectButton = makeButton(@"Eject Disc", self, @selector(ejectDisc:));
    NSButton* scanButton = makeButton(@"Scan CUE Recorder", self, @selector(scanCdrdaoDevices:));
    [_actionButtons addObjectsFromArray:@[listButton, statusButton, ejectButton, scanButton]];
    NSStackView* driveActions = horizontalStack(@[listButton, statusButton, ejectButton, scanButton], 10);
    NSTextField* driveHeading = [NSTextField labelWithString:@"Recorder"];
    NSStackView* driveSection = verticalStack(@[driveHeading, driveActions], 10);

    _statusLabel = [NSTextField labelWithString:@"Ready"];
    _statusLabel.textColor = NSColor.secondaryLabelColor;
    _progress = [[NSProgressIndicator alloc] init];
    _progress.style = NSProgressIndicatorStyleSpinning;
    _progress.controlSize = NSControlSizeSmall;
    _progress.hidden = YES;
    NSStackView* statusRow = horizontalStack(@[_progress, _statusLabel], 8);

    NSTextField* logHeading = [NSTextField labelWithString:@"Activity"];
    logHeading.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    _logView = [[NSTextView alloc] init];
    _logView.editable = NO;
    _logView.selectable = YES;
    _logView.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    _logView.textContainerInset = NSMakeSize(10, 10);
    _logView.frame = NSMakeRect(0, 0, 700, 220);
    _logView.autoresizingMask = NSViewWidthSizable;
    NSScrollView* logScroll = [[NSScrollView alloc] init];
    logScroll.hasVerticalScroller = YES;
    logScroll.borderType = NSBezelBorder;
    logScroll.documentView = _logView;
    [logScroll.heightAnchor constraintGreaterThanOrEqualToConstant:220].active = YES;

    NSView* spacer = [[NSView alloc] init];
    NSStackView* root = verticalStack(@[
        title,
        subtitle,
        mediaSection,
        driveSection,
        statusRow,
        logHeading,
        logScroll,
        spacer
    ], 16);
    root.translatesAutoresizingMaskIntoConstraints = NO;
    root.edgeInsets = NSEdgeInsetsMake(24, 24, 20, 24);
    root.distribution = NSStackViewDistributionFill;
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

    [self appendLog:@"Ready. Burning requires compatible hardware and blank media.\n"];
    [_window center];
    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)windowShouldClose:(id)sender
{
    (void)sender;
    return !_operationRunning;
}

- (void)appendLog:(NSString*)text
{
    if (text.length == 0)
        return;
    [_logView.textStorage appendAttributedString:[[NSAttributedString alloc] initWithString:text]];
    [_logView scrollRangeToVisible:NSMakeRange(_logView.string.length, 0)];
}

- (fs::path)chooseFolderWithPrompt:(NSString*)prompt
{
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.title = prompt;
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    return [panel runModal] == NSModalResponseOK ? fs::path(panel.URL.path.fileSystemRepresentation) : fs::path{};
}

- (fs::path)chooseFileWithPrompt:(NSString*)prompt
{
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.title = prompt;
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    return [panel runModal] == NSModalResponseOK ? fs::path(panel.URL.path.fileSystemRepresentation) : fs::path{};
}

- (fs::path)chooseOutputWithName:(NSString*)name extension:(NSString*)extension
{
    NSSavePanel* panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = [name stringByAppendingPathExtension:extension];
    panel.canCreateDirectories = YES;
    if ([panel runModal] != NSModalResponseOK)
        return {};
    const fs::path result(panel.URL.path.fileSystemRepresentation);
    if (fs::exists(result))
    {
        [self showMessage:@"That output file already exists. Choose a new name; existing files are not overwritten."];
        return {};
    }
    return result;
}

- (void)showMessage:(NSString*)message
{
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"Disc Burner";
    alert.informativeText = message;
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

- (BOOL)confirmBurn:(NSString*)description
{
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = description;
    alert.informativeText = @"Writing a disc is irreversible. Confirm that the recorder and blank media are ready.";
    [alert addButtonWithTitle:@"Burn Disc"];
    [alert addButtonWithTitle:@"Cancel"];
    return [alert runModal] == NSAlertFirstButtonReturn;
}

- (void)runCommands:(std::vector<std::vector<std::string>>)commands
            success:(NSString*)success
       cleanupPath:(std::string)cleanupPath
{
    if (_operationRunning)
        return;
    _operationRunning = YES;
    for (NSButton* button in _actionButtons)
        button.enabled = NO;
    _progress.hidden = NO;
    [_progress startAnimation:nil];
    _statusLabel.stringValue = @"Working…";
    [self appendLog:@"\nStarting operation…\n"];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL succeeded = YES;
        NSMutableString* output = [NSMutableString string];
        for (const auto& command : commands)
        {
            [output appendFormat:@">"];
            for (const auto& argument : command)
            {
                [output appendFormat:@" %s", argument.c_str()];
            }
            [output appendString:@"\n"];
            const CommandResult result = execute(command);
            if (!result.output.empty())
                [output appendString:[NSString stringWithUTF8String:result.output.c_str()]];
            if (result.status != 0)
            {
                succeeded = NO;
                [output appendFormat:@"Command failed with status %d: %@\n", result.status,
                                    [NSString stringWithUTF8String:command.front().c_str()]];
                break;
            }
        }
        if (!cleanupPath.empty())
        {
            std::error_code error;
            fs::remove(cleanupPath, error);
            if (error)
                [output appendFormat:@"Could not remove temporary TOC: %s\n", error.message().c_str()];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self appendLog:output];
            if (succeeded)
            {
                [self appendLog:[success stringByAppendingString:@"\n"]];
                _statusLabel.stringValue = @"Completed";
            }
            else
            {
                _statusLabel.stringValue = @"Operation failed";
            }
            _operationRunning = NO;
            _progress.hidden = YES;
            [_progress stopAnimation:nil];
            for (NSButton* button in _actionButtons)
                button.enabled = YES;
        });
    });
}

- (void)createDataDisc:(id)sender
{
    (void)sender;
    const fs::path source = [self chooseFolderWithPrompt:@"Choose a folder for the data disc"];
    if (source.empty())
        return;
    const fs::path output = [self chooseOutputWithName:stringFromPath(source.filename())
                                              extension:@"iso"];
    if (output.empty())
        return;
    if (![self confirmBurn:@"Create and burn this data disc?"])
        return;

    const NSInteger type = _discType.indexOfSelectedItem;
    std::vector<std::string> command = {"/usr/bin/hdiutil", "makehybrid", "-o", output.string()};
    if (type == 0)
        command.insert(command.end(), {"-udf", "-udf-version", "1.50", "-udf-volume-name", "Blu-ray"});
    else if (type == 1)
        command.insert(command.end(), {"-udf", "-udf-version", "1.02", "-iso", "-joliet"});
    else
        command.insert(command.end(), {"-iso", "-joliet"});
    command.insert(command.end(), {"-default-volume-name", source.filename().string(), source.string()});
    [self runCommands:{command, {"/usr/bin/hdiutil", "burn", "-verifyburn", "-eject", output.string()}}
               success:@"Data disc burned and verified."
          cleanupPath:""];
}

- (void)createDmg:(id)sender
{
    (void)sender;
    const fs::path source = [self chooseFolderWithPrompt:@"Choose a folder for the disk image"];
    if (source.empty())
        return;
    const fs::path output = [self chooseOutputWithName:stringFromPath(source.filename())
                                              extension:@"dmg"];
    if (output.empty())
        return;

    const std::string volume = source.filename().empty() ? "Disk Image" : source.filename().string();
    [self runCommands:{{"/usr/bin/hdiutil", "create", "-srcfolder", source.string(), "-format", "UDZO",
                       "-volname", volume, output.string()}}
               success:@"Compressed DMG created."
          cleanupPath:""];
}

- (void)burnImage:(id)sender
{
    (void)sender;
    const fs::path image = [self chooseFileWithPrompt:@"Choose a disc image"];
    if (image.empty())
        return;
    if (![self confirmBurn:@"Burn this disc image?"])
        return;
    [self runCommands:{{"/usr/bin/hdiutil", "burn", "-verifyburn", "-eject", image.string()}}
               success:@"Disc image burned and verified."
          cleanupPath:""];
}

- (void)burnCue:(id)sender
{
    (void)sender;
    const std::string cue2toc = resolveTool("cue2toc");
    const std::string cdrdao = resolveTool("cdrdao");
    if (cue2toc.empty() || cdrdao.empty())
    {
        [self showMessage:@"CUE burning tools are unavailable. Reinstall the app or add cdrdao and cue2toc to PATH."];
        return;
    }

    const fs::path cue = [self chooseFileWithPrompt:@"Choose a CUE sheet"];
    if (cue.empty())
        return;

    std::string scanOutput;
    const std::vector<DriveDevice> drives = discoverCdrdaoDrives(scanOutput);
    if (drives.empty())
    {
        [self showMessage:driveDiscoveryFailure("No CUE recorder device path was returned.", scanOutput)];
        return;
    }

    NSAlert* deviceAlert = [[NSAlert alloc] init];
    deviceAlert.messageText = @"Select the CD recorder";
    deviceAlert.informativeText = @"Select a device detected by cdrdao.";
    NSPopUpButton* devicePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 320, 28)];
    for (const auto& drive : drives)
    {
        NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:
            [NSString stringWithUTF8String:drive.description.c_str()] action:nil keyEquivalent:@""];
        item.representedObject = [NSString stringWithUTF8String:drive.identifier.c_str()];
        [devicePopup.menu addItem:item];
    }
    deviceAlert.accessoryView = devicePopup;
    [deviceAlert addButtonWithTitle:@"Continue"];
    [deviceAlert addButtonWithTitle:@"Cancel"];
    if ([deviceAlert runModal] != NSAlertFirstButtonReturn || devicePopup.selectedItem == nil)
        return;
    if (![self confirmBurn:@"Burn an audio CD from this CUE sheet?"])
        return;

    std::string tempTemplate = (cue.parent_path() / ".disc-burner-XXXXXX.toc").string();
    std::vector<char> tempName(tempTemplate.begin(), tempTemplate.end());
    tempName.push_back('\0');
    const int file = mkstemps(tempName.data(), 4);
    if (file == -1)
    {
        [self showMessage:[NSString stringWithFormat:@"Could not create a temporary TOC: %s", strerror(errno)]];
        return;
    }
    close(file);

    const fs::path toc(tempName.data());
    const std::string device = [(NSString*)devicePopup.selectedItem.representedObject UTF8String];
    [self runCommands:{{cue2toc, "-o", toc.string(), cue.string()},
                       {cdrdao, "write", "--device", device, "--driver", "generic-mmc", "--eject", toc.string()}}
               success:@"Audio CD burned."
          cleanupPath:toc.string()];
}

- (void)copyDisc:(id)sender
{
    (void)sender;
    const std::string cdrdao = resolveTool("cdrdao");
    if (cdrdao.empty())
    {
        [self showMessage:@"cdrdao is unavailable. Reinstall the app or add it to PATH."];
        return;
    }

    std::string scanOutput;
    const std::vector<DriveDevice> drives = discoverCdrdaoDrives(scanOutput);
    if (drives.size() < 2)
    {
        NSString* message = drives.empty()
            ? driveDiscoveryFailure("No CUE-compatible device paths were returned.", scanOutput)
            : [NSString stringWithFormat:
                @"Only one CUE-compatible drive was found:\n\n%s\n\n"
                 "Copying requires two separate drives: one for the original CD and one for the blank disc.",
                 drives.front().description.c_str()];
        [self showMessage:message];
        return;
    }

    NSAlert* deviceAlert = [[NSAlert alloc] init];
    deviceAlert.messageText = @"Copy an audio or data CD";
    deviceAlert.informativeText =
        @"Insert the original CD in a reader and a blank CD-R/RW in a separate recorder. "
         "This feature copies CDs; it does not copy DVDs or Blu-rays.";
    NSPopUpButton* sourcePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 360, 28)];
    NSPopUpButton* writerPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 360, 28)];
    for (const auto& drive : drives)
    {
        NSString* title = [NSString stringWithUTF8String:drive.description.c_str()];
        NSString* identifier = [NSString stringWithUTF8String:drive.identifier.c_str()];
        NSMenuItem* sourceItem = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
        sourceItem.representedObject = identifier;
        [sourcePopup.menu addItem:sourceItem];
        NSMenuItem* writerItem = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
        writerItem.representedObject = identifier;
        [writerPopup.menu addItem:writerItem];
    }
    if (drives.size() > 1)
        [writerPopup selectItemAtIndex:1];
    NSStackView* fields = verticalStack(@[
        [NSTextField labelWithString:@"Original disc drive"],
        sourcePopup,
        [NSTextField labelWithString:@"Blank disc recorder"],
        writerPopup
    ], 6);
    deviceAlert.accessoryView = fields;
    [deviceAlert addButtonWithTitle:@"Continue"];
    [deviceAlert addButtonWithTitle:@"Cancel"];
    if ([deviceAlert runModal] != NSAlertFirstButtonReturn)
        return;

    if (sourcePopup.selectedItem == nil || writerPopup.selectedItem == nil)
    {
        [self showMessage:@"Select both the source CD drive and the blank-disc recorder."];
        return;
    }
    const std::string source = [(NSString*)sourcePopup.selectedItem.representedObject UTF8String];
    const std::string writer = [(NSString*)writerPopup.selectedItem.representedObject UTF8String];
    if (source == writer)
    {
        [self showMessage:@"Disc copy requires separate source and recorder drives."];
        return;
    }
    if (![self confirmBurn:@"Copy this CD to blank media?"])
        return;

    [self runCommands:{{cdrdao, "copy", "--source-device", source, "--device", writer,
                       "--source-driver", "generic-mmc", "--driver", "generic-mmc", "--eject"}}
               success:@"CD copy completed."
          cleanupPath:""];
}

- (void)listDrives:(id)sender
{
    (void)sender;
    [self runCommands:{{"/usr/bin/drutil", "list"}}
               success:@"macOS drive listing complete. SupportLevel: Unsupported does not mean the drive was not detected."
          cleanupPath:""];
}

- (void)showDriveStatus:(id)sender
{
    (void)sender;
    [self runCommands:{{"/usr/bin/drutil", "info"}, {"/usr/bin/drutil", "status"}}
               success:@"Drive status complete."
          cleanupPath:""];
}

- (void)ejectDisc:(id)sender
{
    (void)sender;
    [self runCommands:{{"/usr/bin/drutil", "tray", "eject"}} success:@"Eject command complete." cleanupPath:""];
}

- (void)scanCdrdaoDevices:(id)sender
{
    (void)sender;
    const std::string cdrdao = resolveTool("cdrdao");
    if (cdrdao.empty())
    {
        [self showMessage:@"cdrdao is unavailable. Reinstall the app or add it to PATH."];
        return;
    }
    [self runCommands:{{cdrdao, "scanbus"}} success:@"Recorder scan complete." cleanupPath:""];
}

@end

int main()
{
    @autoreleasepool
    {
        NSApplication* application = [NSApplication sharedApplication];
        DiscBurnerAppDelegate* delegate = [[DiscBurnerAppDelegate alloc] init];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
