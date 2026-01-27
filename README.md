# $ MiShell 

This repository is my solution to the ["Build Your Own Shell" Challenge](https://app.codecrafters.io/courses/shell/overview). It implements a very basic shell with support for running builtins (exit, echo, type, pwd, cd, history) as well as executables that are in your path.

The currently supported features are:
* Strings without variable interpolation.
* Stdout and stderr redirection via the `>` and `>>` operators.
* Command pipelines via the `|` operator.
* Basic tab completion for builtins and executable files in $PATH only for the first word.
* Up and down arrow history navigation.

On the user input side, cursor movement is limited because I decided not to use a library such as readline and implement the basics myself. Currently apart from tab-completion and history navigation it implements some basic keybord command such as: `Ctrl+C` end of text, `Ctrl-D` end of transimission (same as exit builtin), `Ctrl+L` clears the screen.

## $ How to run it?

To run the project make sure to have **zig** version 0.15.2 installed, then clone the repo and run `zig build run`. It should compile and run effectivley on linux (and probably so on other posix operating systems, though I haven't tried)
