# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0+1]
Date: August 27, 2024

### Added
- Initial release of `router_os_client`.
- Basic API connection functionality for RouterOS devices.
- Added documentation and examples for usage.

## [1.0.0+2]
Date: August 27, 2024

### Changed
- Reformated `router_os_client` file.


## [1.0.0+3]
Date: August 27, 2024

### Removed
- Removed cupertino_icons from dependencies.

## [1.0.2]
Date: August 31, 2024

### Fix
- fix: prevent empty maps from being added to parsed replies

- Modified the `_parseReply` method to ensure that only non-empty maps are added to the `parsedReplies` list. This prevents the unnecessary `{}` from being returned at the end of command execution.

## [1.0.3] 
Date: August 31, 2024

### Changed
- Replace print statements with Logger for consistent logging
- Updated all print statements to use the Logger instance.
- Ensured that verbose logging is handled through the logger for better control.
- Improved error handling and log messaging with appropriate log levels (debug, info, warning, error).

## [1.0.4]
Date: September 2, 2024

### Added
- _parseCommand Method Update:
- Introduced a check to determine if a command part contains an = character.
- Preserved parts containing = without modification to avoid incorrect command formatting.
- Applied a / prefix only to base command parts that do not contain =.
### Fixed
- Command Parsing Issue:
- Resolved an issue where commands with parameters (e.g., profile=1d) were incorrectly parsed by adding an extra = character. This fix ensures that commands such as /ip/hotspot/user/print profile=1d are parsed correctly and sent as /ip/hotspot/user/print with profile=1d as a parameter.
- Corrected the behavior of the client.talk method to ensure proper communication with the RouterOS API, allowing for accurate filtering of data.
### Improved
- Command Handling:
- Enhanced the robustness of the command parsing mechanism, ensuring that commands with parameters are handled accurately and without unintended modifications.

## [1.0.5]
Date: September 7, 2024

### Fixed
- Fixed issue where `talk` function would throw an "invalid arguments" error when `message` is a single string.
- Ensured that single strings passed to `talk` are wrapped in a `List<String>` before sending to `_send` function.

### Changed
- Added explicit handling for `message` when it is a single string to convert it into a list.
- Updated error handling to improve robustness for dynamic inputs.

## [1.0.6]
Date: September 7, 2024

### Added
- Added example project to demonstrate usage of the `router_os_client` package.

## [1.0.7]
Date: September 7, 2024

### Added
- Added Dartdoc comments to all public members and classes, including exceptions (`LoginError`, `WordTooLong`, `CreateSocketError`, `RouterOSTrapError`).
- Renamed anonymous extension to `IntToBytes` for better readability.
- Documented the `IntToBytes` extension with a description for the `toBytes` method.
- 
## [1.0.8]
Date: September 7, 2024

### Change
- Reformatted for pub.dev compliance.


## [1.0.9]
Date: September 9, 2024

### Fixed
- Fixed an issue where logs were displayed even when verbose was set to false.