#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <string>
#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

namespace fs = std::filesystem;

int run(const std::vector<std::string>& arguments)
{
    if (arguments.empty())
        return 1;

    std::vector<char*> argv;
    argv.reserve(arguments.size() + 1);
    for (const auto& argument : arguments)
        argv.push_back(const_cast<char*>(argument.c_str()));
    argv.push_back(nullptr);

    const pid_t child = fork();
    if (child == -1)
    {
        std::cerr << "Could not start " << arguments.front() << ": " << strerror(errno) << '\n';
        return 1;
    }
    if (child == 0)
    {
        execvp(argv[0], argv.data());
        std::cerr << "Could not run " << arguments.front() << ": " << strerror(errno) << '\n';
        _exit(127);
    }

    int status = 0;
    if (waitpid(child, &status, 0) == -1)
    {
        std::cerr << "Could not wait for " << arguments.front() << ": " << strerror(errno) << '\n';
        return 1;
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}

bool available(const std::string& executable)
{
    const char* path = std::getenv("PATH");
    if (path == nullptr)
        return false;

    std::string paths(path);
    std::size_t start = 0;
    while (start <= paths.size())
    {
        const auto end = paths.find(':', start);
        const auto directory = paths.substr(start, end == std::string::npos ? end : end - start);
        if (access((directory + "/" + executable).c_str(), X_OK) == 0)
            return true;
        if (end == std::string::npos)
            break;
        start = end + 1;
    }
    return false;
}

fs::path bundledTool(const std::string& name)
{
#if defined(__APPLE__)
    std::vector<char> executablePath(4096);
    uint32_t pathSize = static_cast<uint32_t>(executablePath.size());
    if (_NSGetExecutablePath(executablePath.data(), &pathSize) == 0)
    {
        std::error_code error;
        const fs::path executable = fs::canonical(executablePath.data(), error);
        if (!error)
        {
            const fs::path contents = executable.parent_path().parent_path();
            const std::vector<fs::path> locations = {
                contents / "Resources" / "libexec" / "disc-burner" / name,
                contents / "libexec" / "disc-burner" / name,
                contents.parent_path() / "libexec" / "disc-burner" / name
            };
            for (const auto& bundled : locations)
            {
                if (access(bundled.c_str(), X_OK) == 0)
                    return bundled;
            }
        }
    }
#endif
    return {};
}

std::string toolCommand(const std::string& name)
{
    const fs::path bundled = bundledTool(name);
    return bundled.empty() ? name : bundled.string();
}

std::string prompt(const std::string& message)
{
    std::cout << message;
    std::string value;
    std::getline(std::cin, value);
    if (value.size() >= 2 && value.front() == '"' && value.back() == '"')
        value = value.substr(1, value.size() - 2);
    return value;
}

bool confirmBurn()
{
    return prompt("This will write a disc. Type BURN to continue: ") == "BURN";
}

bool burnImage(const fs::path& image)
{
    if (!fs::is_regular_file(image))
    {
        std::cerr << "Image file not found: " << image << '\n';
        return false;
    }
    if (!confirmBurn())
    {
        std::cout << "Burn cancelled.\n";
        return false;
    }
    return run({"hdiutil", "burn", "-verifyburn", "-eject", image.string()}) == 0;
}

void createAndBurnDataDisc()
{
    std::cout << "\nDisc type: 1) Blu-ray  2) DVD  3) CD\n";
    const std::string type = prompt("Choose 1-3: ");
    std::vector<std::string> command = {"hdiutil", "makehybrid", "-o"};
    const fs::path output = prompt("Output image path (.iso): ");
    const fs::path source = prompt("Folder to put on the disc: ");

    if (type != "1" && type != "2" && type != "3")
    {
        std::cerr << "Choose Blu-ray, DVD, or CD.\n";
        return;
    }
    if (!fs::is_directory(source))
    {
        std::cerr << "Source folder not found: " << source << '\n';
        return;
    }
    if (output.empty() || fs::exists(output))
    {
        std::cerr << "Choose a new output path; existing files are not overwritten.\n";
        return;
    }

    command.push_back(output.string());
    if (type == "1")
        command.insert(command.end(), {"-udf", "-udf-version", "1.50", "-udf-volume-name", "Blu-ray"});
    else if (type == "2")
        command.insert(command.end(), {"-udf", "-udf-version", "1.02", "-iso", "-joliet"});
    else
        command.insert(command.end(), {"-iso", "-joliet"});
    command.insert(command.end(), {"-default-volume-name", source.filename().string(), source.string()});

    std::cout << "\nCreating disc image...\n";
    if (run(command) != 0)
    {
        std::cerr << "Image creation failed; the disc has not been burned.\n";
        return;
    }
    std::cout << "Image created at " << output << '\n';
    burnImage(output);
}

void createDmg()
{
    const fs::path source = prompt("Folder to package in the disk image: ");
    const fs::path output = prompt("Output DMG path (.dmg): ");

    if (!fs::is_directory(source))
    {
        std::cerr << "Source folder not found: " << source << '\n';
        return;
    }
    if (output.empty() || fs::exists(output))
    {
        std::cerr << "Choose a new output path; existing files are not overwritten.\n";
        return;
    }

    std::string volumeName = source.filename().string();
    if (volumeName.empty())
        volumeName = "Disk Image";

    std::cout << "\nCreating compressed read-only DMG...\n";
    if (run({"hdiutil", "create", "-srcfolder", source.string(), "-format", "UDZO", "-volname", volumeName,
             output.string()}) != 0)
    {
        std::error_code error;
        fs::remove(output, error);
        std::cerr << "DMG creation failed.\n";
        return;
    }
    std::cout << "DMG created at " << output << '\n';
}

void showMenu()
{
    std::cout << "\n=== Disc Burner ===\n"
              << "1) Create and burn a Blu-ray, DVD, or data CD\n"
              << "2) Burn an existing disc image\n"
              << "3) Create a compressed DMG from a folder\n"
              << "4) List optical drives\n"
              << "5) Show drive/media status\n"
              << "6) Eject disc\n"
              << "7) Scan CD recorder devices\n"
              << "0) Quit\n";
}

int main()
{
#if !defined(__APPLE__)
    std::cerr << "This build currently supports macOS only.\n";
    return 1;
#endif

    if (!available("hdiutil") || !available("drutil"))
    {
        std::cerr << "Required macOS tools hdiutil and drutil were not found.\n";
        return 1;
    }

    std::cout << "Disc Burner — data discs and CD copying\n"
              << "Disc writing is irreversible; verify your drive and media before burning.\n";
    while (std::cin)
    {
        showMenu();
        const std::string choice = prompt("> ");
        if (choice == "0")
            break;
        if (choice == "1")
            createAndBurnDataDisc();
        else if (choice == "2")
            burnImage(prompt("Disc image path (ISO/DMG): "));
        else if (choice == "3")
            createDmg();
        else if (choice == "4")
            run({"drutil", "list"});
        else if (choice == "5")
        {
            run({"drutil", "info"});
            run({"drutil", "status"});
        }
        else if (choice == "6")
            run({"drutil", "tray", "eject"});
        else if (choice == "7")
            run({toolCommand("cdrdao"), "scanbus"});
        else if (!choice.empty())
            std::cout << "Unknown option.\n";
    }
    return 0;
}
