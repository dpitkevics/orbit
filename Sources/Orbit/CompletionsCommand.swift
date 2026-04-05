import ArgumentParser
import Foundation

/// Generate shell completions for orbit.
struct Completions: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Generate shell completions.",
        discussion: """
        Generate shell completion scripts for your preferred shell.

        Usage:
          orbit completions zsh > ~/.zfunc/_orbit
          orbit completions bash > /usr/local/etc/bash_completion.d/orbit
          orbit completions fish > ~/.config/fish/completions/orbit.fish
        """
    )

    @Argument(help: "Shell type: zsh, bash, or fish.")
    var shell: String

    func run() {
        switch shell.lowercased() {
        case "zsh":
            let completions = OrbitCLI.completionScript(for: .zsh)
            print(completions)
        case "bash":
            let completions = OrbitCLI.completionScript(for: .bash)
            print(completions)
        case "fish":
            let completions = OrbitCLI.completionScript(for: .fish)
            print(completions)
        default:
            print("Unknown shell '\(shell)'. Supported: zsh, bash, fish.")
        }
    }
}
